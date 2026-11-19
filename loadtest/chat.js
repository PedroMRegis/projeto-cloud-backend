// Teste de carga do chat com k6 — sessão logada (PLANO §11, D-31).
//
// O QUE ESTE TESTE EXERCITA
//   frontend/ALB → chatbot (/api/chat) → backend-api (/api/quotes, /api/orders)
//   → SQS → order-worker → status final do pedido.
//   É o caminho síncrono e o assíncrono na mesma iteração.
//
// POR QUE SESSÃO LOGADA
//   Desde `Exige login para fechar pedido e usa o nome da conta`, `POST /api/orders`
//   exige o cookie `cirro_session`. Sem login o funil para na cotação e o teste
//   deixaria de cobrir SQS e order-worker — ou seja, mediria metade da arquitetura.
//
// POR QUE BOTÕES (`action`) E NÃO TEXTO LIVRE
//   Em `app/application/chat.py`, `mode = "action" if action else (...)`: um turno
//   com `action` é resolvido pelo vendedor determinístico e **nunca** chama o LLM.
//   Isso dá três coisas de graça:
//     1. custo zero de Bedrock mesmo com 100 VUs;
//     2. latência sem a variância do modelo — o que se mede é a infraestrutura
//        (ALB, escala de task, escala de EC2, DynamoDB/RDS, SQS);
//     3. o teste roda contra produção como está, sem redeploy com LLM_PROVIDER=mock.
//   A dimensão "qualidade da conversa" é avaliada à parte, na demo manual.
//
// LIMITE DE LOGIN
//   `rate_limit(10)` em /api/auth/login e /register é por IP, por task. Como a
//   carga sai de um IP só, o login acontece UMA vez no `setup()` para um punhado
//   de contas (POOL) e os VUs reaproveitam os cookies. Logar por VU daria 429.
//
// ESTOQUE — LER ANTES DE UMA EXECUÇÃO LONGA
//   A carga compra de verdade: cada jornada tira 3 a 5 exemplares do catálogo.
//   Um `pico` ou um `soak` esgota os títulos e, a partir daí, o teste para de
//   gerar pedido e passa a medir só o caminho de leitura — a métrica
//   `out_of_stock` subindo é esse sintoma. Reponha o estoque antes
//   (`scripts/ohio/repor-estoque.sh`) e confira `out_of_stock` no fim.
//
// Cenários (-e SCENARIO=...):
//   fumaca   1 VU, 1 min             — valida a jornada antes de gastar carga
//   rampa    0 → 60 VUs em 10 min    — calibra ALBRequestCountPerTarget
//   degrau   10 → 40 → 80 VUs        — mede o tempo de reação da escala
//   pico     5 → 100 VUs em 30 s     — mostra a folga do target_capacity 90
//   soak     30 min a 30 VUs         — procura flapping e vazamento
//   catalogo 200 req/s de leitura    — isola ALB + banco, sem conversa
//
// SEMPRE PASSE `--dns="ttl=5m"`
//   Por padrão o k6 re-resolve o hostname do ALB a cada conexão. Num soak de
//   30 min isso esgotou o resolver da máquina local e produziu 81 erros
//   "no such host" — que parecem queda da aplicação no relatório, mas são do
//   gerador de carga. Com TTL de 5 min o problema some. Se aparecer
//   "no such host" no meio de uma gravação, é isto, não a AWS.
//
// Uso:
//   k6 run --dns="ttl=5m" -e BASE_URL=http://<alb> -e SCENARIO=fumaca loadtest/chat.js
//   k6 run --summary-export=loadtest/results/pico-summary.json \
//          --out json=loadtest/results/pico-raw.json \
//          -e BASE_URL=http://<alb> -e SCENARIO=pico loadtest/chat.js

import http from 'k6/http';
import { check, sleep, fail } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';
import exec from 'k6/execution';
import { randomSeed } from 'k6';

const BASE_URL = (__ENV.BASE_URL || 'http://localhost:8000').replace(/\/$/, '');
const SCENARIO = __ENV.SCENARIO || 'rampa';
// Contas de carga. Prefixo fixo para dar para limpar depois, sufixo configurável
// para não colidir com uma execução anterior que já deixou as contas criadas.
const POOL = Number(__ENV.POOL || 4);
const ACCOUNT_TAG = __ENV.ACCOUNT_TAG || 'k6';
const ACCOUNT_PASSWORD = __ENV.ACCOUNT_PASSWORD || 'carga-k6-2026!';
const COOKIE_NAME = 'cirro_session';

const ordersCreated = new Counter('orders_created');
const ordersSettled = new Counter('orders_settled');
const ordersStuckPending = new Counter('orders_stuck_pending');
const quotesCreated = new Counter('quotes_created');
const loginRequired = new Counter('login_required_unexpected');
const degradedReplies = new Counter('degraded_replies');
const rateLimited = new Counter('rate_limited');
const outOfStock = new Counter('out_of_stock');
const chatLatency = new Trend('chat_turn_duration', true);
const orderSettleTime = new Trend('order_settle_duration', true);
const journeyOk = new Rate('journey_completed');

const SCENARIOS = {
  fumaca: { executor: 'constant-vus', vus: 1, duration: '1m' },
  rampa: {
    executor: 'ramping-vus',
    startVUs: 0,
    stages: [
      { duration: '10m', target: 60 },
      { duration: '2m', target: 60 },
      { duration: '3m', target: 0 },
    ],
  },
  degrau: {
    executor: 'ramping-vus',
    startVUs: 10,
    stages: [
      { duration: '1m', target: 10 },
      { duration: '4m', target: 10 },
      { duration: '1m', target: 40 },
      { duration: '4m', target: 40 },
      { duration: '1m', target: 80 },
      { duration: '4m', target: 80 },
      { duration: '2m', target: 0 },
    ],
  },
  pico: {
    executor: 'ramping-vus',
    startVUs: 5,
    stages: [
      { duration: '2m', target: 5 },
      { duration: '30s', target: 100 },
      { duration: '5m', target: 100 },
      { duration: '2m', target: 5 },
    ],
  },
  soak: { executor: 'constant-vus', vus: 30, duration: '30m' },
  catalogo: {
    executor: 'constant-arrival-rate',
    rate: 200,
    timeUnit: '1s',
    duration: '5m',
    preAllocatedVUs: 50,
    maxVUs: 200,
  },
};

if (!SCENARIOS[SCENARIO]) {
  fail(`SCENARIO desconhecido: ${SCENARIO}. Use: ${Object.keys(SCENARIOS).join(', ')}`);
}

export const options = {
  scenarios: { [SCENARIO]: SCENARIOS[SCENARIO] },
  thresholds: {
    // Durante a escala há latência alta pontual; o que não se aceita é erro.
    http_req_failed: ['rate<0.01'],
    'http_req_duration{expected_response:true}': ['p(95)<5000'],
    checks: ['rate>0.98'],
    // Nenhum pedido pode ficar preso em PENDING: é a prova de que o caminho
    // assíncrono drena mesmo quando a task que criou o pedido morre.
    orders_stuck_pending: ['count==0'],
    login_required_unexpected: ['count==0'],
  },
  tags: { scenario: SCENARIO },
  // Sem isso, um 401 ou 429 esperado polui a métrica de erro do ALB.
  discardResponseBodies: false,
};

const TERMOS = [
  'ficção distopia', 'Machado de Assis', 'fantasia', 'livro de tecnologia',
  'Tolkien', 'clássico brasileiro', 'Saramago', 'Clean Code',
  'Duna', 'O Pequeno Príncipe', 'não-ficção história', 'Clarice Lispector',
];

function uuid() {
  // crypto.randomUUID não existe no runtime do k6.
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    const v = c === 'x' ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}

function sessionCookie(res) {
  const jar = res.cookies[COOKIE_NAME];
  return jar && jar.length ? jar[0].value : null;
}

// --------------------------------------------------------------------- setup

export function setup() {
  randomSeed(42);

  const health = http.get(`${BASE_URL}/health`, { tags: { endpoint: 'health' } });
  if (health.status !== 200) {
    fail(`alvo não está saudável: ${BASE_URL}/health -> ${health.status}`);
  }

  if (SCENARIO === 'catalogo') return { cookies: [] };

  // Até 2 chamadas por conta (register, e login se já existia) — com POOL=4 são
  // no máximo 8, dentro do rate_limit(10) por IP das rotas de conta.
  const cookies = [];
  for (let i = 0; i < POOL; i += 1) {
    const email = `carga+${ACCOUNT_TAG}${i}@convcommerce.test`;
    const body = { email, password: ACCOUNT_PASSWORD, name: `Carga K6 ${i}` };
    const headers = { 'Content-Type': 'application/json' };

    // 409 = conta já existe. É resultado normal da segunda execução em diante,
    // então não pode contar como erro HTTP e estourar o threshold de falha.
    let res = http.post(`${BASE_URL}/api/auth/register`, JSON.stringify(body), {
      headers,
      tags: { endpoint: 'register' },
      responseCallback: http.expectedStatuses(201, 409),
    });
    if (res.status === 409) {
      // Conta sobrou de uma execução anterior: é só entrar.
      res = http.post(`${BASE_URL}/api/auth/login`,
        JSON.stringify({ email, password: ACCOUNT_PASSWORD }),
        { headers, tags: { endpoint: 'login' } });
    }
    if (res.status !== 200 && res.status !== 201) {
      fail(`não consegui preparar a conta ${email}: ${res.status} ${res.body}`);
    }
    const cookie = sessionCookie(res);
    if (!cookie) fail(`login de ${email} não devolveu o cookie ${COOKIE_NAME}`);
    cookies.push(cookie);
  }

  console.log(`setup: ${cookies.length} sessões prontas contra ${BASE_URL}`);
  return { cookies };
}

export function teardown() {
  // As contas de carga ficam de propósito: a próxima execução reaproveita por
  // login e a evidência (pedidos por conta) continua consultável no backoffice.
}

// ------------------------------------------------------------------ jornada

// O cookie jar do k6 é por VU e não herda o do `setup()`, então a sessão vai
// como header explícito. Cada VU fica com uma conta fixa do pool: assim os
// pedidos da carga ficam distribuídos entre contas, como no mundo real.
function sessionHeader() {
  const cookie = SESSION_COOKIES[exec.vu.idInTest % SESSION_COOKIES.length];
  return { Cookie: `${COOKIE_NAME}=${cookie}` };
}

let SESSION_COOKIES = [];

function postChat(message, conversationId, action) {
  const requestId = uuid();
  const payload = { message, request_id: requestId };
  if (conversationId) payload.conversation_id = conversationId;
  if (action) payload.action = action;

  const res = http.post(`${BASE_URL}/api/chat`, JSON.stringify(payload), {
    headers: {
      'Content-Type': 'application/json',
      'X-Request-Id': requestId,
      ...sessionHeader(),
    },
    timeout: '60s',
    tags: { endpoint: 'chat', action: (action && action.type) || 'texto' },
  });
  chatLatency.add(res.timings.duration);

  if (res.status === 429) { rateLimited.add(1); return null; }
  check(res, { 'chat respondeu 200': (r) => r.status === 200 });
  if (res.status !== 200) return null;

  const body = res.json();
  if (body.degraded) degradedReplies.add(1);
  // login_required aqui significa que o cookie não chegou — o funil pararia na
  // cotação e o teste mediria menos do que pensa. Falha explícita, não silenciosa.
  if (body.login_required) loginRequired.add(1);
  if (body.quote) quotesCreated.add(1);
  return body;
}

function pollOrder(orderId, conversationId) {
  const started = Date.now();
  for (let i = 0; i < 20; i += 1) {
    sleep(1.5);
    const res = http.get(
      `${BASE_URL}/api/orders/${orderId}?conversation_id=${conversationId}`,
      { headers: sessionHeader(), tags: { endpoint: 'order_status' } },
    );
    if (res.status === 200 && res.json('status') !== 'PENDING') {
      const status = res.json('status');
      orderSettleTime.add(Date.now() - started);
      ordersSettled.add(1);
      check(res, {
        'pedido saiu de PENDING': () => ['CONFIRMED', 'REJECTED'].includes(status),
      });
      return status;
    }
  }
  // 30 s sem sair de PENDING: ou o Pipe não publicou, ou o order-worker não
  // consumiu. É exatamente a falha que a demo de drenagem precisa não produzir.
  ordersStuckPending.add(1);
  return 'PENDING';
}

export default function (data) {
  if (SCENARIO === 'catalogo') {
    const termo = TERMOS[Math.floor(Math.random() * TERMOS.length)];
    const res = http.get(`${BASE_URL}/api/products?q=${encodeURIComponent(termo)}`, {
      tags: { endpoint: 'products' },
    });
    check(res, {
      'catálogo respondeu 200': (r) => r.status === 200,
      'catálogo devolveu resultados': (r) => r.json('count') >= 0,
    });
    return;
  }

  SESSION_COOKIES = data.cookies;
  const termo = TERMOS[Math.floor(Math.random() * TERMOS.length)];

  // 1. busca. Conversa nova a cada iteração: o rate limit do chatbot é de
  //    20 msg/min POR CONVERSA, então reusar conversa limitaria a carga.
  let turno = postChat(termo, null, { type: 'search', query: termo });
  if (!turno) { journeyOk.add(false); sleep(1); return; }
  const conversationId = turno.conversation_id;

  // 2. se a busca trouxe uma lista, escolhe o primeiro resultado.
  if (turno.stage === 'browsing') {
    // Esgotados ficam no fim da lista de resultados, então procurar um com
    // estoque evita gastar a jornada num livro que não dá para vender.
    const produto = (turno.products || []).find((p) => p.in_stock !== false);
    if (!produto) { outOfStock.add(1); journeyOk.add(true); return; }
    turno = postChat('esse', conversationId,
      { type: 'select_product', product_id: produto.product_id });
    if (!turno) { journeyOk.add(false); return; }
  }
  // Fora de `product` só sobra livro esgotado: resposta de negócio correta.
  if (turno.stage !== 'product') { outOfStock.add(1); journeyOk.add(true); return; }

  sleep(Math.random() * 1.5 + 0.5); // tempo de leitura do cliente

  // 3. quantidade ≥ 3 para cair na faixa de desconto e exercitar a política
  //    de preço no servidor.
  const quantidade = 3 + Math.floor(Math.random() * 3);
  turno = postChat(`${quantidade}`, conversationId,
    { type: 'set_quantity', quantity: quantidade });
  if (!turno) { journeyOk.add(false); return; }
  // Estoque pode ter acabado sob carga — é resposta legítima, não erro.
  if (turno.stage !== 'quoted') { outOfStock.add(1); journeyOk.add(true); return; }

  // 4. metade dos clientes pede desconto.
  if (Math.random() < 0.5) {
    turno = postChat('tem desconto?', conversationId,
      { type: 'request_discount', discount_pct: 10 });
    if (!turno) { journeyOk.add(false); return; }
  }

  sleep(Math.random() * 1.5 + 0.5);

  // 5. confirma. Com sessão logada isto cria o pedido de verdade.
  turno = postChat('confirmo', conversationId, { type: 'confirm' });
  if (!turno) { journeyOk.add(false); return; }
  if (!turno.order_id) {
    // Sem order_id e sem login_required = cotação expirou ou estoque sumiu.
    journeyOk.add(!turno.login_required);
    return;
  }
  ordersCreated.add(1);

  // 6. polling do status: é isto que exercita Pipe → SQS → order-worker.
  const status = pollOrder(turno.order_id, conversationId);
  journeyOk.add(status !== 'PENDING');

  sleep(Math.random() * 2);
}

# Prompt de handoff — rodar a carga e gravar as provas de funcionamento

Copie deste ponto até o fim do arquivo e cole no outro chat.

---

## Contexto do projeto

**Cirro Livros** — projeto semestral de Computação em Nuvem (Insper). Uma
livraria onde o cliente compra conversando com um vendedor de IA. O repositório
de orquestração é `projetocloud`; as três aplicações vivem em repositórios
próprios, clonados em `repos/`:

| Repositório | Papel |
|---|---|
| `repos/projeto-cloud-backend` | `backend-api` (FastAPI) + `order-worker`. Única porta para o PostgreSQL. |
| `repos/projeto-cloud-chatbot` | `chatbot` (FastAPI). Conversa, chama o backend por HTTP. LLM via Bedrock. |
| `repos/projeto-cloud-frontend` | `frontend` (React/Vite). Estático. |

**Onde está rodando:** AWS Ohio (`us-east-2`), conta `108791993403`, etapa
manual (console + AWS CLI, sem Terraform ainda). Prefixo `convcommerce-prod`.

- ALB público: `http://convcommerce-prod-alb-516489552.us-east-2.elb.amazonaws.com`
- Cluster ECS `convcommerce-prod`, capacity provider EC2 (`t3.small`), ASG min 2 / max 4
- Serviços: `backend-api` (2–8), `chatbot` (2–8), `order-worker` (1–6), `frontend` (2 fixo)
- Fila `convcommerce-prod-orders-queue` + DLQ, visibility 60 s
- Inventário em `docs/recursos-ohio.md`

**Fluxo de uma compra:** navegador → ALB → `chatbot` `/api/chat` → `backend-api`
`/api/quotes` e `/api/orders` → outbox no Postgres → SQS → `order-worker` debita
estoque e confirma → o cliente vê o pedido sair de `PENDING`.

### Duas ressalvas sobre o repositório

1. **`docs/recursos-ohio.md` foi regerado em 2026-11-19** a partir da AWS e
   descreve o que está no ar: RDS PostgreSQL com outbox e Bedrock.
2. **`repos/projeto-cloud-backend` está no branch local `migracao-dynamodb`**,
   que divergiu e **não** está contido em `origin/main`. O que roda em produção
   é `origin/main`. Não dê `git pull` cego nesse repositório.

---

## Estado: o que já foi feito e verificado

Tudo abaixo foi **executado de verdade** contra produção em 2026-11-17, não é
plano. Leia `docs/evidencias/ohio/ANALISE.md` antes de qualquer coisa — ele tem
os números e o problema aberto.

| Item | Estado |
|---|---|
| k6 v2.4.0 instalado (`C:\Program Files\k6`) | ✅ |
| `loadtest/chat.js` com sessão logada | ✅ rodado, 30 min de soak |
| `scripts/ohio/_task-avulsa.sh` (helper) | ✅ |
| `scripts/ohio/repor-estoque.sh` | ✅ 21 de 40 títulos repostos |
| `scripts/ohio/97-observa-escala.sh` | ✅ CSV gerado |
| `scripts/ohio/98-resiliencia.sh troca-task` | ✅ 2 min 40 s, sem queda |
| `scripts/ohio/98-resiliencia.sh perde-task` | ✅ recuperou em < 30 s |
| `scripts/ohio/98-resiliencia.sh drena-instancia` | ❌ **não ensaiado** |
| `scripts/ohio/99-consistencia.sh` | ✅ 5/5 invariantes OK |

**O único script não verificado é a drenagem de instância**, porque terminar
uma EC2 de produção precisa de decisão humana. Ele foi dividido em duas fases:

```bash
scripts/ohio/98-resiliencia.sh drena-instancia    # reversível, só drena
scripts/ohio/98-resiliencia.sh reativa-instancia  # desfaz
TERMINAR=1 scripts/ohio/98-resiliencia.sh drena-instancia   # ciclo completo
```

**Ensaie a drenagem antes de gravar.** É a prova mais longa (~5 min até a
substituta registrar) e a única sem precedente de execução.

### O problema aberto que muda o roteiro

As políticas de auto scaling estão calibradas ~10× abaixo da carga real. Medido
no ALB: `RequestCountPerTarget` ficou em **~290/min por alvo** com o alvo da
política em **30**. Resultado: com 30 VUs, tudo vai ao teto (8 tasks, 4 EC2) em
dois minutos e fica lá.

Os dois níveis de elasticidade funcionam — e é isso que o enunciado pede — mas
o gráfico mostra *saturação*, não escala proporcional. **Os cenários `degrau`
(80 VUs) e `pico` (100 VUs) não vão mostrar escalonamento nenhum**: vão mostrar
erro. Houve 18 timeouts na janela de subida.

Decida antes de gravar (detalhes e opções em `ANALISE.md`):

- **Mínimo:** gravar com **10–12 VUs**, não 30. A escala fica visível e sem erro.
- **Recomendado:** recalibrar o alvo para ~250 (chatbot) e ~400 (backend-api),
  rodar `rampa` antes e depois, e **narrar a calibração**. "Medimos, estava
  errado, calibramos, aqui está a diferença" é exatamente a análise quantitativa
  que a rubrica A+ pede — vale mais que um gráfico plano no teto.

### Três decisões do teste de carga, para narrar

1. **Login uma vez, no `setup()`.** `/api/auth/login` tem `rate_limit(10)` por
   IP por task; logar por VU daria 429 em massa.
2. **A jornada usa botões (`action`), não texto livre.** Em `chat.py`,
   `mode = "action" if action else (...)`: turno com `action` é resolvido pelo
   vendedor determinístico e **nunca chama o LLM**. Custo zero de Bedrock,
   latência sem a variância do modelo, nenhum redeploy. **Diga isso na
   apresentação** — mede-se a infraestrutura, não a conversa.
3. **A carga compra de verdade.** O soak de 30 min zerou 21 de 40 títulos.
   Reponha antes de cada cenário longo e confira a métrica `out_of_stock`.

---

## Preparação

```bash
aws sso login && aws sts get-caller-identity
export PATH="$PATH:/c/Program Files/k6"
cd /c/Users/joses/documents/insper/2026-2/projetocloud
source scripts/ohio/00-config.sh
export BASE_URL=http://convcommerce-prod-alb-516489552.us-east-2.elb.amazonaws.com

curl -s "$BASE_URL/health"
scripts/ohio/98-resiliencia.sh estado
scripts/ohio/repor-estoque.sh 300
```

---

## Roteiro de gravação

Três terminais lado a lado, todos no vídeo — a causa (T2), o efeito (T3) e a
experiência do cliente (T1) na mesma imagem, com o mesmo relógio.

```
┌──────────────────┬──────────────────┬──────────────────┐
│ T1  k6           │ T2  comandos     │ T3  escala (CSV) │
└──────────────────┴──────────────────┴──────────────────┘
```

Abra também o console em **ECS → Cluster → Tasks** e em **EC2 → Auto Scaling
Groups → Activity**: o CSV prova, o console convence.

### Bloco 1 — escala de tasks e de instâncias

**T3 primeiro**, depois **T1**:

```bash
scripts/ohio/97-observa-escala.sh 1500 15
k6 run --summary-export=loadtest/results/degrau-summary.json \
       -e BASE_URL="$BASE_URL" -e SCENARIO=degrau loadtest/chat.js
```

⚠ Com a calibração atual, `degrau` satura. Se você não recalibrou, troque por
um cenário de 10–12 VUs. A cadência real do CSV é ~30 s (as chamadas de AWS CLI
levam ~15 s no Windows).

**O que narrar:**

1. Baseline no mínimo, alarme ainda não disparou.
2. `*_desired` sobe antes de `*_running` — **nomeie esse atraso**, é o tempo de
   puxar imagem e passar no health check. É a resposta a "em quanto tempo
   vocês escalam?".
3. Quando as tasks não cabem mais, `asg_desired` sobe e aparece task em
   `PENDING` esperando capacidade. **Segundo nível de elasticidade** — é o
   momento mais importante do bloco.
4. Uma instância pode aparecer com **0 tasks** enquanto outras enchem: é o
   `binpack` por MEMORY fazendo o trabalho dele, empacotando nas existentes
   antes de usar a vazia. Explique, senão parece defeito.
5. Descida mais lenta que a subida (ScaleOut 60 s / ScaleIn 300 s) é
   deliberado: subir cedo custa centavos, descer cedo custa disponibilidade.

### Bloco 2 — troca, perda e drenagem

Carga de fundo no T1 e o T3 gravando o tempo todo. Espere ~2 min de regime.
Sem carga nada disso prova nada: o ponto não é que a task volta, é que **o
cliente não percebe**.

```bash
scripts/ohio/98-resiliencia.sh troca-task backend-api     # planejada
scripts/ohio/98-resiliencia.sh perde-task order-worker    # não planejada
TERMINAR=1 scripts/ohio/98-resiliencia.sh drena-instancia # infraestrutura
```

Do mais controlado para o mais violento. **Espere estabilizar entre eles.**

**Troca de task** (medido: 2 min 40 s). `runningCount` nunca abaixo do mínimo,
k6 sem erro. O ALB **primeiro** tira a task do target group, **depois** ela
recebe SIGTERM; o deregistration delay cobre a requisição em curso.

**Perda de task** (medido: volta em < 30 s). Narre no CSV: `fila_em_voo` sobe →
a task morre → passado o visibility timeout de 60 s a mensagem **volta para
`fila_visiveis`** → outra task consome → o pedido sai de `PENDING`. Diga
explicitamente que o estoque **não** é debitado duas vezes, e que isso é
idempotência no `order-worker`, não sorte: a entrega do SQS é *pelo menos uma
vez*, então reprocessar é o esperado, não a falha.

⚠ No ensaio a fila nunca acumulou — o `order-worker` deu conta sozinho e a
prova ficou discreta. Para aparecer no vídeo, mate o worker num momento de
vazão de pedido alta, ou derrube `desiredCount` para 0 por um minuto antes.

**Drenagem** (não ensaiado). Ciclo completo: instância vai para `DRAINING`, o
ECS reagenda as tasks **antes** de a EC2 morrer, o ASG sobe a substituta e ela
registra (~3 min). Mostre `ec2_draining` indo a 1 e voltando a 0, e
`ec2_inservice` retornando. **Deixe o CSV gravando até a substituta entrar** —
cortar antes deixa a prova pela metade.

### Bloco 3 — fecho: nenhum dado se perdeu

```bash
scripts/ohio/99-consistencia.sh
```

Roda `check_consistency.py` dentro de uma task avulsa (o RDS é privado; o
script monta a `DATABASE_URL` com `db_credentials.current_password()`, o mesmo
caminho que a aplicação usa para sobreviver à rotação de 7 dias do RDS).

Verifica, e falha com exit 1 se alguma quebrar:

1. `stock` = soma dos movimentos do livro-razão;
2. todo pedido `CONFIRMED` debitou cada item exatamente uma vez;
3. pedido não confirmado não debitou estoque;
4. nenhum pedido `PENDING` há mais de 10 min;
5. nenhum evento do outbox sem publicar há mais de 5 min.

**Grave a saída.** No ensaio deu **5/5 OK com 1561 pedidos** (1540 confirmados,
21 rejeitados por estoque) **depois** de uma task morta e um deployment sob
carga. Mostre junto o `orders_stuck_pending: 0` do k6: um diz que o banco está
íntegro, o outro que o cliente foi atendido.

---

## Entregáveis

Em `docs/evidencias/ohio/`: os CSVs `escala-*.csv`, os `consistencia-*.txt`, o
vídeo, e o **`ANALISE.md` atualizado** com os números que você vai dizer em voz
alta — p95 por patamar, tempo até a primeira task nova, tempo até a instância
nova, tempo de recuperação. A rubrica A+ pede *análise quantitativa*: o CSV é
matéria-prima, o número dito é a entrega.

Em `loadtest/results/`: os `*-summary.json`.

E atualize `docs/recursos-ohio.md` (ressalva 1) e o `NOTES.md`.

## Se der errado

| Sintoma | Causa |
|---|---|
| `login_required_unexpected > 0` | cookie não chegou ao chatbot: `auth_jwt_secret` divergente |
| `out_of_stock` alto | catálogo esgotado — `repor-estoque.sh` |
| `orders_stuck_pending > 0` | outbox ou worker parados — achado real, investigue |
| timeout no `/api/chat` sob carga | saturação: tudo no teto. Ver `ANALISE.md` |
| `aws` sai com exit 255 e erro de `charmap` | codepage do Windows; prefixe `PYTHONUTF8=1` |
| 403 em `/api/admin*` | esperado: regra 10 do ALB bloqueia admin na borda |
| task avulsa não sobe | sem capacidade no cluster; espere o scale-in |

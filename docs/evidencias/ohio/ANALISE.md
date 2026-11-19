# Análise do ensaio de 2026-11-17

Ensaio completo contra Ohio (`us-east-2`), conta `108791993403`, com a
aplicação em produção. Tudo aqui foi medido, não estimado.

Evidências brutas:
`escala-20261117T150225Z.csv`, `consistencia-*.txt`,
`loadtest/results/resiliencia-summary.json`.

## O soak de 30 minutos, 30 VUs — números fechados

```
iterations ........ 19 467        http_reqs ......... 50 860  (28,2 req/s)
checks OK ......... 99,77 %       http_req_failed ... 0,22 %  (114)
journey_completed . 99,41 %       login_required .... 0
p50 ............... 356 ms        p95 ............... 772 ms
pedidos criados ... 2 817         pedidos liquidados  2 817
orders_stuck_pending ............ 0
tempo até sair de PENDING: p50 1,70 s · p95 1,75 s · max 25,0 s
```

**2817 pedidos criados, 2817 liquidados, nenhum preso.** O caminho assíncrono
(outbox → SQS → order-worker) fechou 100 % dos pedidos, com p95 de 1,75 s,
inclusive durante o deployment e a morte de uma task do worker.

Os 0,22 % de falha se decompõem em duas causas, e **nenhuma das duas é da
aplicação**:

- **18 timeouts** num único intervalo (15:13), a janela em que a 4ª instância
  entrava e as tasks novas ainda não passavam no health check;
- **81 erros `no such host`** — DNS da **máquina geradora**, não da AWS. O k6
  re-resolve o hostname do ALB a cada conexão e esgotou o resolver local.
  Corrigido em `loadtest/chat.js`: rode sempre com `--dns="ttl=5m"`. Se isso
  aparecer durante a gravação, é o gerador, não o sistema.

**`out_of_stock`: 16 531.** O catálogo (40 títulos × 300 exemplares = 12 000)
foi consumido inteiro pelos 2817 pedidos. A maior parte das jornadas, na
segunda metade do soak, terminou em "esgotado" em vez de virar pedido. Para um
soak de 30 min, reponha com **3000 por título**, não 300.

## O que funcionou

| Prova | Resultado |
|---|---|
| Reposição de estoque por task avulsa | 21 de 40 títulos repostos, exit 0 |
| Troca de task (`backend-api`, rolling) | 2 min 40 s, `runningCount` nunca abaixo de 2 |
| Parada de task (`order-worker`, `stop-task`) | serviço de volta a 1/1 em < 30 s, fila nunca acumulou |
| Invariantes do banco, depois das duas falhas | **5 de 5 OK** — 1561 pedidos, 1540 confirmados, 21 rejeitados por estoque |

O `check_consistency.py` rodando **depois** de matar task sob carga é o fecho
do argumento de "sem perda de dados": nenhum pedido preso em `PENDING`, nenhum
estoque debitado duas vezes, outbox sem evento parado.

## O problema que o ensaio encontrou

> **Correção.** A primeira versão desta análise dizia que o problema era
> calibração — alvo 30 contra ~290 medidos. Medir a CPU e o target group
> interno mostrou outra coisa: são **dois problemas diferentes, um em cada
> serviço**, e o do `backend-api` é um bug, não um número mal escolhido.

### `backend-api`: a política observa o target group errado

A política `requests-per-target` do `backend-api` aponta para:

```
app/convcommerce-prod-alb/…/targetgroup/convcommerce-prod-backend/…
```

que é o target group do **ALB público**. Mas quem chama o backend é o chatbot,
**pelo ALB interno**. Medido durante o soak:

| Target group | req/alvo/min |
|---|---|
| `convcommerce-prod-backend` (público, o que a política observa) | **0,1 – 2,4** |
| `convcommerce-prod-backend-int` (interno, onde o tráfego está) | **590 – 632** |

A política está vigiando um target group praticamente ocioso. **Ela nunca
dispara.** O `backend-api` escala hoje só por CPU, por acidente — o segundo
sinal, que o projeto desenhou de propósito, está desligado sem que nada
indicasse isso.

Correção: trocar o `ResourceLabel` para o target group interno e calibrar o
alvo. Com 8 tasks a CPU ficou em 14–20 % no regime, então 8 tasks é folga
grande demais; um alvo de **1500 req/alvo/min** põe o serviço em 3–4 tasks
nesta carga, que é proporcional.

### `chatbot`: não é calibração, está genuinamente sem CPU

Aqui o alvo de 30 contra ~290 medidos realmente está errado, mas corrigi-lo
não mudaria nada, porque a **outra** política já manda escalar:

```
CPUUtilization do chatbot durante o soak (média / máximo por 5 min)
12:00   82 % / 254 %      12:15  125 % / 138 %
12:05  150 % / 317 %      12:20   94 % / 131 %
12:10   83 % / 269 %      12:25   72 % / 586 %
```

O alvo da política de CPU é 60 %. Com média entre 72 % e 150 % — acima de 100 %
da reserva de 256 unidades (0,25 vCPU) — o chatbot está saturado de verdade com
8 tasks. Subir o alvo de requisições não resolve: a CPU continuaria pedindo
mais tasks, e o máximo é 8.

Para comparação, o `backend-api` no mesmo período ficou em 14–52 % de CPU.
O gargalo do sistema é o chatbot, e a causa é tamanho de task, não política.

Correção de verdade: **512 unidades de CPU por task** em vez de 256 (exige nova
task definition e deployment). Correção para a gravação: **gravar com 10–12
VUs**, onde a CPU fica na faixa de 30–50 % e a escala aparece proporcional.

### O efeito combinado, no CSV

Resultado às 15:08, dois minutos depois de a carga começar:

```
ts                    backend  chatbot  asg_desired  ec2
15:07:57Z             2,2      2,2      3            3
15:08:27Z             4,4      8,3      3            3     <- vai ao teto
15:08:58Z             4,4      8,8      3            3
15:13:03Z             8,9      8,8      4            4     <- ASG no máximo
...e fica em 8,8 / 8,8 / 4,4 até o fim
```

Os dois níveis de elasticidade **funcionam** — task e instância subiram, e isso
é exatamente o que o enunciado pede. Mas subiram até o teto em dois minutos e
não voltaram, então o gráfico não mostra escala *proporcional à carga*: mostra
saturação. Para a rubrica A+ ("análise quantitativa da estabilidade sob
variações de carga"), isso é um resultado fraco.

Consequências diretas para a gravação:

1. **Os cenários `degrau` (80 VUs) e `pico` (100 VUs) não vão mostrar
   escalonamento.** Tudo já está no máximo com 30. Eles vão mostrar fila de
   espera e erro.
2. Houve **18 timeouts** em 30 minutos, todos num único intervalo às 15:13 —
   a janela em que a 4ª instância entrava e as tasks novas ainda não passavam
   no health check. Transiente de escala, não saturação sustentada, mas é erro
   visível para o cliente e vai aparecer no vídeo se a carga for alta.
3. O `order-worker` **nunca escalou**: ficou em 1 task e a fila ficou em 0 o
   tempo todo. A política por `BacklogPerTask` está certa conceitualmente, mas
   nunca é exercitada porque o gargalo está antes, no chatbot. Para demonstrar
   o segundo perfil de escalabilidade é preciso ou mais vazão de pedido, ou
   segurar o worker artificialmente.

### Uma armadilha de unidade, que explica o chute original

`ALBRequestCountPerTarget` é a **soma de requisições por alvo no período de um
minuto**, não requisições por segundo. Um alvo de 30 significa 0,5 req/s por
task — valor que nenhuma aplicação real sustenta. O comentário em
`96-autoscaling.sh` ("60 requisições por minuto por task é o ponto de partida;
o valor definitivo…") mostra que o número era provisório, e a calibração — que
era justamente o propósito do cenário `rampa` — nunca foi feita.

### O que fazer, em ordem

| # | O que fazer | Efeito | Custo |
|---|---|---|---|
| 1 | Apontar a política do `backend-api` para o TG **interno**, alvo 1500 | Liga um sinal de escala que hoje está morto | 1 comando, reversível |
| 2 | Gravar com 10–12 VUs em vez de 30 | Escala proporcional e visível, sem erro | Nenhum |
| 3 | Subir o alvo de requisições do chatbot de 30 para ~250 | Tira um sinal que só gera ruído; a CPU passa a mandar sozinha | 1 comando, reversível |
| 4 | Subir CPU da task do chatbot de 256 para 512 | Ataca a causa do gargalo | Novo deployment |
| 5 | Subir `ASG_MAX` de 4 para 6 | Folga de instância para o `pico` | Custo de EC2 |

**Para a gravação: 1 + 2 + 3.** O item 1 é correção de defeito e deve entrar de
qualquer jeito. O 4 é a correção arquitetural certa, mas exige deployment e
pode ficar para depois da entrega — desde que seja **dito** na apresentação,
porque "sabemos onde está o gargalo e por quê" é melhor que silêncio.

Narrar a sequência — medimos, descobrimos que uma das políticas observava o
target group errado, corrigimos, e aqui está o antes e o depois — é exatamente
a análise quantitativa que a rubrica A+ pede.

### Comandos (não executados: o ambiente bloqueia mutação em produção)

```bash
source scripts/ohio/00-config.sh

# 1. backend-api: apontar para o ALB interno e calibrar
ALB_INT=$(aws elbv2 describe-load-balancers --region "$REGION" \
  --names "${PREFIX}-internal" --query 'LoadBalancers[0].LoadBalancerArn' --output text)
LABEL="${ALB_INT#*:loadbalancer/}/${TG_BACKEND_INTERNAL#*:targetgroup/}"
aws application-autoscaling put-scaling-policy --region "$REGION" \
  --service-namespace ecs \
  --resource-id "service/${CLUSTER}/${PREFIX}-backend-api" \
  --scalable-dimension ecs:service:DesiredCount \
  --policy-name requests-per-target --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration "{\"TargetValue\":1500.0,\
\"PredefinedMetricSpecification\":{\"PredefinedMetricType\":\"ALBRequestCountPerTarget\",\
\"ResourceLabel\":\"${LABEL}\"},\"ScaleOutCooldown\":60,\"ScaleInCooldown\":300}"

# 3. chatbot: tirar o alvo de requisições do caminho
aws application-autoscaling put-scaling-policy --region "$REGION" \
  --service-namespace ecs \
  --resource-id "service/${CLUSTER}/${PREFIX}-chatbot" \
  --scalable-dimension ecs:service:DesiredCount \
  --policy-name requests-per-target --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration "{\"TargetValue\":250.0,\
\"PredefinedMetricSpecification\":{\"PredefinedMetricType\":\"ALBRequestCountPerTarget\",\
\"ResourceLabel\":\"$(aws elbv2 describe-load-balancers --region "$REGION" \
  --names "${PREFIX}-alb" --query 'LoadBalancers[0].LoadBalancerArn' --output text \
  | sed 's|.*:loadbalancer/||')/${TG_CHATBOT#*:targetgroup/}\"},\
\"ScaleOutCooldown\":60,\"ScaleInCooldown\":300}"
```

**Depois de aplicar, atualize `scripts/ohio/96-autoscaling.sh`** — senão a
próxima execução dele reverte a correção e o bug volta sem ninguém perceber.

## Depois da correção — medido em 19/11

As políticas corrigidas foram aplicadas por `96-autoscaling.sh` (a correção
está no script, não em comando solto, para a próxima execução não revertê-la).
Mesma carga de antes, 30 VUs:

> **A janela válida desta rodada é 11:28–11:40, não os 30 min.** O CloudWatch
> mostra `RequestCountPerTarget` caindo a **zero** às 11:40: a rede da máquina
> geradora colapsou e o k6 passou os últimos 18 minutos sem entregar
> requisição (daí `http_req_duration max=14m24s` e 4,4 req/s de média no
> relatório — números do gerador, não do sistema). Tudo abaixo vale para a
> janela de 12 minutos em que houve carga de verdade.

| Serviço | Antes (17/11) | Depois (19/11, janela válida) |
|---|---|---|
| `backend-api` | 2 → **8** em 2 min, fica no teto | **2**, estável |
| `chatbot` | 2 → **8** em 2 min | 2 → 5 → **8** |
| req/alvo/min no chatbot | ~290 | 2379 (11:30-11:35), 618 (11:35-11:40) |
| CPU do chatbot | 72-150 % | 186 % (11:30-11:35), 60 % (11:35-11:40) |
| erros HTTP | 114 de 50 860 (0,22 %) | 128 de 14 418 (0,88 %) — **todos do gerador** |

**O `backend-api` é a prova de que a correção funcionou.** Com a política
apontando para o target group certo e calibrada em 1500, ele atende a mesma
carga com **2 tasks em vez de 8** — quatro vezes menos capacidade para o mesmo
trabalho, e sem degradar a latência. Antes ele escalava por um sinal que não
media nada.

**O `chatbot` continua indo ao teto, e isso confirma o diagnóstico**: a subida
agora é gradual (2 → 5 → 8, acompanhando a carga, em vez de saltar direto),
mas a política de CPU leva ao máximo de qualquer jeito, porque o serviço está
genuinamente sem CPU. Corrigir o alvo de requisições tornou a escala
proporcional; não criou capacidade que não existe.

Conclusão para a apresentação: **a elasticidade está certa, o
dimensionamento do chatbot não está.** São coisas diferentes e vale dizer as
duas. A correção de verdade é 512 unidades de CPU por task — o que muda a conta
de capacidade (8 × 512 = 4096 unidades, contra 2048 por `t3.small`), então
exige revisar `ASG_MAX` junto. Não foi feito porque é decisão de arquitetura
com custo, não ajuste de parâmetro.

## Drenagem de instância — medido em 19/11

Ciclo completo, com 30 VUs de carga rodando:

```
11:30:52  instância i-088c037282eeedf92 marcada DRAINING, com 4 tasks
11:32:40  0 tasks — as 4 migraram em 1 min 48 s
11:33:19  terminada pelo ASG (--no-should-decrement-desired-capacity)
11:34:08  substituta registrada no cluster
```

No CSV, `ec2_draining` vai a 1 às 11:33:30 e volta a 0 às 11:34:22. **Nenhum
serviço caiu abaixo do mínimo em momento algum** (backend 2/2, chatbot 2/2,
frontend 2/2 durante toda a janela) e o k6 **não registrou um único erro**.

O `order-worker` subiu para 2 tasks entre 11:31:32 e 11:32:19 e voltou para 1:
é o ECS reagendando a task que estava na instância drenada antes de deixá-la
morrer — exatamente o comportamento que a demo precisa mostrar.

E o `99-consistencia.sh` rodado **depois** do ciclo completo: **5 de 5
invariantes OK sobre 5 586 pedidos** (5 551 confirmados, 35 rejeitados por
estoque). É a evidência mais forte do conjunto — o cluster perdeu uma
instância inteira sob carga e o banco continuou íntegro.

### Dois bugs encontrados no próprio script

**1. `98-resiliencia.sh`** — `--should-decrement-desired-capacity false` não
existe: é flag booleana, e o CLI responde `Unknown options: false`. A forma
correta é `--no-should-decrement-desired-capacity`. Corrigido. **Era exatamente
o tipo de falha que teria aparecido ao vivo** — a drenagem rodou até o fim e só
quebrou no último comando, com a instância já vazia.

**2. `97-observa-escala.sh`** — o `set -e` herdado do `00-config.sh` fazia um
único erro transiente de rede (`Could not connect to the endpoint URL`) matar o
observador e levar junto o resto do CSV. Aconteceu aos 10 minutos do ensaio.
Corrigido com `set +e` no laço: agora uma amostra falha sai com campo vazio —
um furo visível no gráfico, não a perda da evidência inteira.

### Sobre a máquina que gera a carga

Três falhas distintas desta rodada e da anterior vieram do mesmo lugar, e
**nenhuma da AWS**: 81 erros de DNS (17/11), a morte do observador por erro de
conexão, e o colapso da carga às 11:40. Para a gravação, isso importa mais que
parece — um erro do gerador no meio do vídeo é indistinguível de uma falha do
sistema para quem assiste. Rode sempre com `--dns="ttl=5m"`, e se os números
parecerem absurdos (p95 de minutos, vazão despencando), confira o
`RequestCountPerTarget` no CloudWatch **antes** de culpar a aplicação.

## Pendente

- A cadência real do `97-observa-escala.sh` é de ~30 s, não os 15 s pedidos:
  as três chamadas de AWS CLI levam ~15 s no Windows. Para granularidade fina,
  use o CloudWatch; o CSV serve para a narrativa.

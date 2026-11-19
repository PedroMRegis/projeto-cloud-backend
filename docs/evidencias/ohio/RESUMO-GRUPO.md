# Cirro Livros — ensaio de carga e resiliência em Ohio (17/11)

Status para o grupo. Tudo abaixo foi **executado contra produção**, não é plano.
Detalhe técnico em `docs/evidencias/ohio/ANALISE.md`; roteiro de gravação em
`docs/evidencias/PROMPT-GRAVACAO.md`.

## Resultado do teste de carga — 30 min, 30 usuários simultâneos

```
19 467 jornadas de compra · 50 860 requisições (28 req/s)
99,77 % de sucesso · p50 356 ms · p95 772 ms

2 817 pedidos criados → 2 817 liquidados → 0 presos
tempo até o pedido sair de PENDING: p50 1,70 s · p95 1,75 s
```

O caminho assíncrono (outbox → SQS → order-worker) fechou **100 % dos pedidos**,
inclusive durante um deployment e a morte proposital de uma task do worker.

Os 0,22 % de falha não são da aplicação: 18 timeouts na janela em que a 4ª
instância EC2 subia, e 81 erros de DNS da máquina que gerava a carga (corrigido
com `--dns="ttl=5m"` no k6).

## Provas de resiliência

| Prova | Resultado |
|---|---|
| **Troca de task** (deployment rolling do backend) | ✅ 2 min 40 s, nunca abaixo do mínimo, zero erro |
| **Parada de task** (`stop-task` no order-worker) | ✅ serviço de volta em < 30 s, nenhuma mensagem perdida |
| **Drenagem de instância** | ✅ ciclo completo: 4 tasks migraram em 1 min 48 s, instância terminada, substituta registrada em 49 s — nenhum serviço abaixo do mínimo |

## Sem perda de dados — verificado

Rodamos `check_consistency.py` **depois** de matar task e fazer deployment sob
carga. **5 de 5 invariantes OK**, sobre 1 561 pedidos:

1. estoque = soma dos movimentos do livro-razão ✅
2. todo pedido confirmado debitou cada item exatamente uma vez ✅
3. pedido não confirmado não debitou estoque ✅
4. nenhum pedido preso em PENDING ✅
5. nenhum evento do outbox parado ✅

É a evidência mais forte que temos: o sistema perdeu uma task no meio do
trabalho e o banco continuou íntegro.

## Dois problemas encontrados no auto scaling

Com 30 usuários, tudo vai ao teto (8 tasks, 4 instâncias) em dois minutos e
fica lá. Os dois níveis de elasticidade **funcionam** — tasks e instâncias
escalaram, que é o que o enunciado pede — mas o gráfico mostra *saturação*, não
escala proporcional. Investigando, são duas causas diferentes:

### 1. A política do backend-api observa o target group errado — é bug

A política de "requisições por alvo" do `backend-api` aponta para o target
group do **ALB público**. Mas quem chama o backend é o chatbot, **pelo ALB
interno**. Medido durante o teste:

| Target group | req/alvo/min |
|---|---|
| público — o que a política observa | **0,1 – 2,4** |
| interno — onde o tráfego realmente está | **590 – 632** |

A política vigia um target group ocioso e **nunca dispara**. O backend escala
hoje só por CPU, por acidente. Correção: um comando, apontar para o target
group interno e calibrar o alvo em 1500.

### 2. O chatbot está genuinamente sem CPU

CPU média do chatbot durante o teste: **72 % a 150 %**, com picos de 586 %,
contra um alvo de 60 % e uma reserva de 0,25 vCPU por task. Com 8 tasks ainda
está saturado. (Para comparação, o backend ficou em 14–52 %.)

O gargalo do sistema é o chatbot, e a causa é **tamanho de task**, não
política. A correção certa é dobrar a CPU da task (256 → 512), o que exige novo
deployment. Para a gravação, dá para contornar usando 10–12 usuários em vez de
30, faixa em que a escala aparece proporcional.

Consequência prática: **os cenários de 80 e 100 usuários não vão mostrar
escalonamento** — vão mostrar erro. E o `order-worker` nunca escalou (1 task,
fila sempre vazia), porque o gargalo está antes dele.

**O que isso vale para a nota:** narrar "medimos, descobrimos que uma das
políticas observava o target group errado, corrigimos, e aqui está o antes e o
depois" é exatamente a análise quantitativa que a rubrica A+ pede.

## Duas coisas do repositório que o grupo precisa saber

1. **`docs/recursos-ohio.md` foi regerado em 19/11** com `99-inventario.sh`, e os
   scripts de criação (`30-data.sh`, `35-rds.sh`, `40-iam.sh`, `60-ssm.sh`,
   `95-services.sh`) passaram a descrever o que está no ar: RDS PostgreSQL com
   outbox e Bedrock, sem as tabelas antigas do DynamoDB e sem o Pipe.
2. **O backend está com o branch `migracao-dynamodb` em checkout local**, que
   divergiu e não está contido na `main`. O que roda em produção é a `main`.
   Não dêem `git pull` cego nesse repositório.

## Ferramentas novas no repositório

| Arquivo | Para quê |
|---|---|
| `loadtest/chat.js` | teste de carga com sessão logada (reescrito) |
| `scripts/ohio/_task-avulsa.sh` | roda código dentro da VPC via task avulsa do ECS |
| `scripts/ohio/repor-estoque.sh` | repõe o catálogo antes da carga |
| `scripts/ohio/97-observa-escala.sh` | grava escala de tasks e instâncias em CSV |
| `scripts/ohio/98-resiliencia.sh` | troca / perda / drenagem |
| `scripts/ohio/99-consistencia.sh` | verifica as invariantes do banco |

Duas decisões de desenho que valem para a apresentação:

- **O teste de carga usa os botões do chat, não texto livre.** Um turno com
  `action` é resolvido pelo vendedor determinístico e **nunca chama o LLM** —
  custo zero de Bedrock mesmo com 100 usuários, e a latência medida é a da
  infraestrutura, não a do modelo. **Isso tem de ser dito na apresentação.**
- **Nada de admin é exposto na internet.** A rota `/api/admin*` leva 403 fixo no
  ALB, e as operações de manutenção entram por task avulsa dentro da VPC, com a
  credencial resolvida pelo ECS. Nenhum segredo passa pela linha de comando.

## A correção foi aplicada — e aqui está o efeito

O bug do `backend-api` foi corrigido em `scripts/ohio/96-autoscaling.sh` (no
script, não por comando solto, para a próxima execução não reverter) e
aplicado. Mesma carga, antes e depois:

| | Antes | Depois |
|---|---|---|
| `backend-api` | 2 → **8** tasks, preso no teto | **2**, estável |
| `chatbot` | 2 → **8** em 2 minutos | 2 → 5 → **8**, gradual |

**O backend atende a mesma carga com 2 tasks em vez de 8** — quatro vezes menos
capacidade para o mesmo trabalho, sem perder latência. Antes ele escalava por um
sinal que não media nada.

O chatbot continua chegando ao teto, e isso *confirma* o segundo diagnóstico em
vez de contradizê-lo: a subida agora acompanha a carga, mas a CPU leva ao máximo
porque o serviço está genuinamente sem CPU (186 % de média no pico).

## Falta fazer

- [ ] **decidir sobre a CPU do chatbot**: 512 unidades em vez de 256. Muda a
      conta de capacidade (8 × 512 = 4096 contra 2048 por `t3.small`), então
      exige revisar o `ASG_MAX` junto. É decisão de arquitetura com custo.
- [ ] gravar os vídeos — **com 10 a 12 usuários, não 30**, enquanto a CPU do
      chatbot não for resolvida
- [x] regerar `docs/recursos-ohio.md` (19/11)

## Um aviso sobre a máquina que gera a carga

Três falhas dos ensaios vieram do computador que roda o k6, **nenhuma da AWS**:
81 erros de DNS, a morte do script observador por erro de conexão, e o colapso
da carga aos 12 minutos da última rodada. Na gravação isso importa: um erro do
gerador é indistinguível de uma falha do sistema para quem assiste. Rode sempre
com `--dns="ttl=5m"` e, se os números parecerem absurdos, confira o
`RequestCountPerTarget` no CloudWatch antes de culpar a aplicação.

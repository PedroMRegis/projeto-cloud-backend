# `scripts/ohio` — operação da etapa manual em Ohio

Scripts de AWS CLI que criaram e operam a infraestrutura de `us-east-2`.
Vieram do repositório `joselsm3/projeto-cloud-insper`, que o grupo deixou de
usar em outubro; moraram lá até 19/11/2026.

Eles estão **aqui**, e não nos outros dois repositórios, porque dependem deste:
`99-consistencia.sh` executa `scripts/check_consistency.py`, e
`repor-estoque.sh` importa `app.application.admin`. Manter os dois lados no
mesmo repositório evita que uma mudança no `app/` quebre a operação sem
ninguém perceber.

## Como usar

Todos esperam ser carregados depois do `00-config.sh`, que lê o state file
(`docs/evidencias/ohio/recursos.env`) com os IDs dos recursos criados:

```bash
source scripts/ohio/00-config.sh
scripts/ohio/98-resiliencia.sh estado
```

## O que é o quê

| Script | Para quê |
|---|---|
| `00-config.sh` | identidade, nomes, state file, helpers. Carregue primeiro. |
| `10-` … `95-` | criação da infraestrutura, na ordem numérica |
| `96-autoscaling.sh` | políticas de escala de task |
| `97-observa-escala.sh` | grava tasks, instâncias e fila em CSV |
| `98-resiliencia.sh` | troca de task, perda de task, drenagem de instância |
| `99-consistencia.sh` | verifica as invariantes do banco |
| `99-inventario.sh` | regenera `docs/recursos-ohio.md` |
| `_task-avulsa.sh` | helper: roda código dentro da VPC |
| `repor-estoque.sh` | repõe o catálogo antes de um teste de carga |

## Três coisas que não são óbvias

**Operação entra por task avulsa do ECS, não por rota exposta.** O RDS é
privado e `/api/admin*` leva 403 fixo no ALB público. `_task-avulsa.sh`
reaproveita a task definition e a task role do `backend-api`: mesmo código,
credenciais resolvidas pelo ECS, dentro da VPC, e a task some ao terminar.
Nenhum segredo passa pela linha de comando. Foi a alternativa a expor o banco,
abrir a rota de admin, ou ligar ECS Exec (que substitui as tasks do serviço).

**Repor estoque passa por `admin.adjust_stock`, nunca por `UPDATE`.** Cada
ajuste tem de virar movimento no livro-razão; um `UPDATE products SET stock`
quebraria a invariante `stock = Σ movimentos` do `check_consistency.py`.

**No Windows, prefixe `PYTHONUTF8=1` ao ler log pelo CLI.** O `aws.exe` escreve
no console com a codepage ANSI e morre com `UnicodeEncodeError` em qualquer
caractere fora dela — o `Σ` do `check_consistency.py` derruba a leitura inteira
com exit 255 e uma mensagem sem relação com a causa. `PYTHONIOENCODING` não
resolve: o CLI v2 é binário congelado e só `PYTHONUTF8` chega ao interpretador.

## Evidências

`docs/evidencias/ohio/ANALISE.md` tem os números do ensaio de 17 e 19/11 e os
dois problemas de auto scaling encontrados. `docs/evidencias/PROMPT-GRAVACAO.md`
é o roteiro das provas de funcionamento.

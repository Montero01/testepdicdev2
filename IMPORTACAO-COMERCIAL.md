# Importação de pedidos — Comercial / Vendas

Os responsáveis explicitamente autorizados no Comercial têm o botão **Importar XLS** na página Comercial. O fluxo é: escolher ListaPedidos, definir o período/situações, conferir os vínculos entre Funcionário e participante do PDI, gerar a prévia e confirmar. A confirmação exige reconhecer que a exportação deve conter todos os pedidos dos vendedores/dias selecionados.

O leitor identifica o cabeçalho, ignora linhas vazias/observações/rodapé e concilia a quantidade e o valor final com o total geral quando não há erros na origem. Lê XLS BIFF e XLSX com SheetJS 0.20.3 local, em Worker, sem executar macros ou recalcular fórmulas. Limite de 20 MB, 100 mil linhas, 201 colunas e 30 segundos de leitura. O arquivo é processado no navegador; não é armazenado no Supabase.

## Matriz suportada

| Indicador | Campo / regra |
|---|---|
| Quantidade de vendas | Números distintos de pedido; não Núm. Peças |
| Valor vendido | Valor Final, em centavos por pedido |
| Área vendida | Total m², em milésimos por pedido |
| Vendas sem desconto · quantidade | Pedidos com Desconto Total explicitamente igual a zero |
| Vendas sem desconto · valor | Valor Final dos pedidos sem desconto |

Funcionário e Data definem o participante/dia. O sufixo `(Cad.: ...)` indica quem cadastrou, sem substituir o responsável do pedido. Sugestões de vínculo só ocorrem quando todos os nomes completos do relatório coincidem com tokens de um único perfil; abreviações ou divergências exigem seleção manual. Todos os vínculos precisam ser conferidos. Funcionários fora da campanha podem ser explicitamente ignorados; não são criados usuários automaticamente.

Por padrão, são selecionadas as situações Conferido COM, Confirmado PCP, Liberado Parcialmente e Liberado. O usuário pode selecionar outras situações visíveis no arquivo. Somente datas dentro da campanha e até hoje são importáveis. Erros Excel, números de pedido duplicados, falta de colunas ou campos inválidos no recorte impedem a confirmação. Os nomes dos clientes e referências livres não são usados para inferir produtos ou novos clientes.

Habitat/Laminado, orçamentos, novos clientes, reposições internas e Bitrix24 não constam desse modelo e não são inferidos. Se já preenchidos, permanecem iguais. Em dias novos, ficam `null` (pendentes), com exibição `—`/Pendente. Conversão sem orçamentos informados permanece sem base. Ticket médio usa as vendas efetivamente importadas. Avaliação e ranking sinalizam pontuação parcial enquanto existirem pendências.

O vendedor pode abrir **Complementar indicadores** no próprio lançamento importado e preencher os campos ainda pendentes. Não pode modificar dados importados, alterar campos anteriormente preenchidos, trocar participante/data ou excluir. Coordenação/gerência/Diretoria conservam os ajustes autorizados. Os campos pendentes numéricos aparecem vazios: o zero precisa ser informado pelo usuário. Bitrix24 requer seleção explícita Usou/Não usou.

## Atualização e rastreabilidade

A importação substitui os cinco totais do participante/dia; não soma aos anteriores. Importar relatório parcial para um dia substituirá os totais desse dia pelos pedidos presentes no arquivo, por isso a confirmação de completude é necessária. Dias ausentes não são excluídos nem zerados. Indicadores manuais são preservados, e a operação é bloqueada se a redução das vendas tornar Habitat/Laminado incompatíveis com os totais.

Repetir o mesmo arquivo/vínculo não duplica valores. Os pedidos ficam rastreados em `import_source` na mesma `pdi_sales_daily`; não há tabela por arquivo/gráfico/vendedor. Um pedido já vinculado a outro participante/data bloqueia a nova atribuição até a gestão revisar o lançamento original. Revisões dos registros e da campanha detectam alterações desde a prévia. O lote é uma transação: se qualquer grupo falhar, nenhum grupo é salvo.

`pdi_performance_events` recebe os eventos com usuário autenticado, data, justificativa, antes/depois, nome/hash SHA-256 do arquivo, IDs dos pedidos e lote. Reimportações sem alteração também deixam um resumo auditável. O CSV existente mantém os campos pendentes identificados; os logs têm exportação própria.

Testes: leitura do relatório real enviado e conciliação de quantidade/valor, testes sintéticos de cabeçalhos/descontos/duplicidade/vínculos, 22 verificações SQL de permissões, pendências, preservação, complemento próprio, concorrência e atomicidade, testes DOM da prévia/confirmação e do formulário de complemento. As verificações anteriores de cálculos, Master, interface, gráficos, CSS e expansões também passaram. Sem renderização visual em navegador real nesta sessão. Nenhum pedido do arquivo enviado foi inserido automaticamente: o usuário confirma a prévia na aplicação.

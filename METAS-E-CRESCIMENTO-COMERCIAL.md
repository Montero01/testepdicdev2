# Metas individuais, aderência e crescimento — Comercial

## Período de visualização e período de avaliação

Importação, registro diário e consulta permitem histórico desde 2000 até hoje, independentemente das datas da campanha. O filtro de visualização consulta o período escolhido e, por padrão, começa no primeiro lançamento disponível. Gráficos e detalhamento histórico continuam exibindo esse recorte. Nenhum registro histórico é apagado quando as datas da campanha são ajustadas.

A avaliação da campanha começa em **15/11/2026** e termina na menor data entre hoje e o fim configurado da campanha. Vendas, pedidos, Bitrix24, novos clientes e reposições anteriores ao início não entram nessa avaliação. O ranking e as metas usam esse período próprio; mudar o filtro dos gráficos não recalcula a campanha a partir de um recorte arbitrário.

## Até três metas por participante

Em Metas individuais, os responsáveis autorizados podem configurar zero a três valores em R$, positivos e crescentes. As faixas são opcionais, sequenciais e independentes por vendedor. Consultores veem somente as próprias metas/resultados; configuração continua exclusiva da gestão comercial já autorizada.

- Meta diária = meta total ÷ 30.
- Dias transcorridos = dias corridos desde 15/11, incluindo a data inicial e hoje, limitados a 30.
- Esperado até a data = meta diária × dias transcorridos.
- Avanço sobre a meta total = vendido ÷ meta total × 100.
- Taxa de aderência = vendido ÷ esperado até a data × 100.

No exemplo de 19/11, transcorreram cinco dias. Uma meta de R$ 60.000 tem meta diária de R$ 2.000 e esperado de R$ 10.000. Vender R$ 9.000 representa 15% da meta integral e 90% de aderência ao ritmo. Após o 30º dia, o esperado fica limitado à meta integral. Não há calendário de dias úteis, horas ou feriados: o divisor fixo de 30 foi adotado conforme a definição da campanha.

As três faixas são indicadores comparativos; não foi criado bônus de pontos por atingir uma faixa, pois esse bônus não foi especificado.

## Dois indicadores de crescimento, peso 3 cada

A referência histórica fica no mês de início da campanha. Para a campanha de novembro, os seis meses completos anteriores são maio a outubro de 2026; novembro não entra na própria base histórica. Essa referência permanece estável durante a campanha, inclusive em dezembro.

- Média mensal de vendas = soma de vendas dos seis meses ÷ 6.
- Venda esperada no ciclo = média mensal × 1,20.
- Média mensal de pedidos = soma de pedidos dos seis meses ÷ 6.
- Pedidos esperados no ciclo = média mensal × 1,20.

O valor esperado é arredondado para cima ao centavo e a quantidade para cima ao pedido inteiro. Cada indicador recebe uma meta proporcional aos dias transcorridos, usando o mesmo divisor de 30.

Pontos de crescimento de vendas = 3 × mínimo(aderência de vendas ÷ 100, 1).
Pontos de crescimento de pedidos = 3 × mínimo(aderência de pedidos ÷ 100, 1).

São até seis pontos adicionais ao conjunto de regras existente. Os critérios de desempate continuam Bitrix24, conversão, menos erros e maior ticket médio. As regras existentes não foram apagadas ou receberam metas fictícias.

## Conferência do histórico

Os seis meses devem ser confirmados individualmente pela gestão, com justificativa auditável. Ausência de registros não significa zero: confirmar um mês sem registros declara explicitamente que seu total foi zero. Se faltar um mês confirmado, houver campos de venda ausentes ou a média for zero, o indicador fica pendente/sem base e não ganha pontos. Os totais mensais usados no cálculo ficam disponíveis no painel de parâmetros.

A configuração permite como alternativa o mês inteiro, mas o padrão desta campanha é contar desde 15/11. Alterar esse parâmetro exige gestão, justificativa e controle de revisão.

## Persistência, acessos e testes

Os lançamentos continuam em pdi_sales_daily, sem cópias para gráficos. pdi_sales_targets guarda somente metas e conferência histórica por participante/referência, na mesma base Supabase, com RLS que permite consulta própria ao vendedor e consulta/configuração aos responsáveis autorizados. Não há acesso novo por cargo genérico nem alteração da lista de responsáveis do Comercial.

Revisões da campanha e das metas evitam sobrescrever alterações concorrentes. Configuração, metas individuais e conferências geram eventos em pdi_performance_events, com identidade autenticada e antes/depois. A atualização de estrutura fica registrada como operação administrativa, sem simular um usuário autenticado.

Foram testados cortes em 14/15/19 de novembro, continuidade do ciclo em dezembro, limite de 30 dias, três faixas, médias de seis meses, acréscimo de 20%, pontuação de peso 3, pendências, isolamento por vendedor e configuração com revisão. Os testes SQL verificaram também o histórico fora da campanha, a preservação do acesso restrito e a auditoria. Testes DOM, cálculos, importação, gráficos, arquivos, CSS e expansões passaram. Não houve inspeção visual em navegador real nesta sessão.

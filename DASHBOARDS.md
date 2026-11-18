# Dashboards por setor — 17/11/2026

PCP e Caixa seguem as abas internas e o padrão de cartões da Logística. Visão Geral, Registro diário, Lançamentos, Desperdício e Log gerencial aparecem conforme as permissões já existentes. Gerência e Diretoria continuam sem formulário de coleta.

Cada setor possui quatro painéis recolhidos inicialmente: barras comparativas, pizza, evolução diária com tendência e dispersão. Seletores de indicadores ficam dentro dos painéis. Filtros de período e colaborador permanecem compartilhados; Logística também conserva veículo. Rankings e detalhamentos anteriores ficam em áreas expansíveis. Cada gráfico inclui tabela acessível com seus dados.

## Origem e cálculos

A migração 20261117204503 altera apenas as três funções de dashboard existentes. Nenhuma tabela nova, cópia por gráfico ou por mês. As consultas usam os registros atuais e preservam RLS e logs. No Caixa, totais, série diária e agrupamento por caixa usam um único conjunto filtrado materializado. Valores financeiros continuam em centavos inteiros no banco e no transporte.

PCP: barras de salvo/analisado/desperdício/aproveitamento; pizza de salvo, desperdício e demais áreas aproveitadas somente em registros completos (salvo já faz parte do analisado); evolução selecionável; dispersão analisado versus salvo ou desperdício. Dados ausentes permanecem pendentes, nunca viram zero.

Caixa: barras por operador; pizza por meio de pagamento; evolução diária selecionável; dispersão quantidade de fechamentos versus resultado. Crédito parcelado representa o total informado, não a liquidação bancária nem lucro.

Logística: barras por veículo; pizza por setor de reposição ou tipo de manutenção; evolução das movimentações; dispersão m² versus km. Não representa consumo de combustível, pois não existe hodômetro por abastecimento.

A tendência é regressão linear pelos dias reais decorridos, descritiva, sem previsão. Só aparece com dois dias distintos informados. Barras exibem os 12 maiores resultados; tabela mantém todos. Gráficos SVG locais, sem bibliotecas ou serviços externos, com cores próprias para tema claro/escuro e grade adaptável.

## Verificação

101 verificações de interface, 22 de gráficos, 46 de CSS/contraste/responsividade, 26 de SQL local com dados fictícios. Conferidos filtros, restrição de acesso, valores ausentes, tendência com datas irregulares e centavos. Em produção, total do Caixa igual à soma diária e por operador; impressões digitais dos registros PCP/Caixa/Logística idênticas antes/depois e 40 tabelas públicas mantidas. Testes não substituem inspeção visual em navegador real; esta não estava disponível neste ambiente.

Avisos de segurança do Supabase anteriores à alteração permanecem: funções legadas com search_path mutável e SECURITY DEFINER público, além da configuração Auth de senhas vazadas. Referências: https://supabase.com/docs/guides/database/database-linter?lint=0011_function_search_path_mutable e https://supabase.com/docs/guides/database/database-linter?lint=0028_anon_security_definer_function_executable . Nenhuma permissão foi ampliada nesta entrega.

# Desperdício independente, distribuição logística e fotos

## PCP

A aba Desperdício permite selecionar PCP, data até hoje, m² desperdiçados e observação/lista de reposições antes de existir resultado diário. Zero é uma conferência válida. Foram mantidas as permissões de Rodrigo F. L. Campos e da gerência de Produção já autorizada; o próprio PCP não lança desperdício.

A tabela pdi_pcp_waste continua sendo a fonte do indicador: id identifica o desperdício e entry_id é o vínculo opcional com o resultado diário. PCP e data têm unicidade para registros ativos. Não foi criada outra tabela de indicadores nem foram preenchidos m² analisados ou salvos fictícios. No momento da migração não havia desperdícios cadastrados; os resultados diários históricos foram preservados.

Quando o PCP lança o resultado diário do mesmo dia, a vinculação acontece automaticamente. O desperdício mantém sua autoria original. A análise precisa comportar os m² salvos e desperdiçados; um valor incompatível é recusado. Até existir análise, os percentuais ficam pendentes. Os totais de desperdício já aparecem no dashboard, inclusive quando ainda não há diário. As observações da reposição são preservadas separadamente da justificativa de correção.

Filtros, listas, CSV, auditoria, revisão e exclusão gerencial consideram também os registros independentes. Exclusão usa o id do desperdício; ao excluir um diário vinculado, a exclusão dependente continua sendo auditada. Reenvio da mesma criação não duplica o registro.

## Logística

Distribuição por categoria oferece Internas × Externas em quantidade, arrecadado e gasto informado em R$. Movimentações/pedidos registrados × Reposições oferece quantidade e m². Quantidade significa ocorrências cadastradas, não pedidos distintos que o sistema não identifica. Reposições mantêm área em m² e lista nas observações; não foi criado custo em R$ para reposições.

As opções existentes de reposição por setor e manutenção por tipo foram mantidas. A distribuição usa o mesmo recorte e filtros de data, veículo e colaborador, com registros ativos e não excluídos. Campos ausentes não viram valores financeiros zero.

## Erika Glass

As fotos salvas e as prévias locais das visitas têm Ampliar foto. Um segundo diálogo permite visualizar a imagem maior, com Escape, retorno de foco e suporte a telas pequenas. O formulário e seus rascunhos permanecem abertos. Não há nova assinatura de URL, upload ou publicação de arquivo; são reutilizados o blob local ou a URL privada temporária já obtida.

## Validação

Testes reais com authenticated e rollback cobriram Rodrigo registrando desperdício antes do diário, correção, zero, autoria, acesso negado ao próprio PCP, revisão obsoleta, vinculação automática, aproveitamento, ausência de duplicação e exclusão em cascata. Os testes temporários foram revertidos. O RPC da Logística foi validado com os dados autorizados e filtros, além dos testes simulados dos gráficos.

Passaram os testes de interface, integração visual, novo formulário de desperdício, sete opções de distribuição e 19 verificações de ampliação de fotos. Essas verificações visuais usam DOM simulado; não houve teste de pixels ou câmera física.

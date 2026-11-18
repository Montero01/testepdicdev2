# Estoque, PCP e cadastros — 18/11/2026

## Estoque

A coleta está vinculada exclusivamente à conta existente Vitor Amaral por identificador estável, sem alterar seu cargo/setor ou dar acesso à operação completa da Logística. O menu Desempenho > Estoque permite registrar veículo/equipamento (incluindo Munck cadastrado na frota), m², km e observações. Tipo Interna fixo, data do dia de Manaus, sem taxa, arrecadação, gastos, combustível, jornada, exclusão ou edição pelo colaborador. Munck é tratado como veículo/equipamento, não como processo separado.

O registro é uma linha da mesma tabela `pdi_logistics_records`, com `origin_module=stock`. Não existe uma tabela paralela nem cópia da movimentação. `created_by` é atribuído pelo trigger com a sessão autenticada, e a identificação do autor fica no snapshot e no log. O Vitor consulta somente seus registros de Estoque. A Diretoria pode consultar o Estoque sem lançar dados. Os indicadores consolidados e CSV de Logística já incluem essas movimentações, e o CSV também informa a origem.

Gabriele Costa Lima já possui supervisão de Logística e continua consultando e corrigindo esses registros pela Logística, com justificativa e revisão. A autoria original não muda: `updated_by` registra quem ajustou. Correções não podem converter a movimentação do Estoque em externa nem incluir valores financeiros. A integração não cria jornada para o Vitor nem cadastro de motorista.

## PCP

Somente a conta Rodrigo F. L. Campos (confirmada pelo Diretor como Rodrigo Freire) conserva a permissão de supervisão para corrigir lançamentos e registrar desperdício. Outros supervisores podem consultar conforme seus escopos, mas não ajustar PCP nem desperdício. A coleta do próprio PCP permanece como antes; gerência de Produção mantém a exceção já existente para registrar desperdício; Diretoria continua somente consulta operacional. Cargo e demais permissões do Rodrigo não foram alterados.

## Cadastros da Logística

Gerência de Produção passa a cadastrar/ajustar pessoas e veículos, além da gerência de Logística e Diretoria já autorizadas. Quando a pessoa só possui essa liberação, a interface abre somente Cadastros e não concede coleta operacional nem indicadores de Logística. Pessoas e veículos exibem autor do cadastro e da última alteração. As mudanças continuam gerando os logs existentes com ator, antes/depois, data e justificativa.

## Validação e instalação

Migração 20261118144206_stock_internal_movements_and_named_pcp_supervisor aplicada à base CDE. Nenhuma tabela operacional adicional. Preservados 28 registros de Logística, oito pessoas e seis veículos existentes no momento da alteração; hashes dos dados PCP e Caixa permaneceram iguais. Adicionada somente a origem aos registros legados com valor Logística, sem apagar seu histórico.

127 verificações de interface, 25 de arquivos, 22 de gráficos e 46 de CSS/contraste/regras responsivas. No Postgres local, verificados Vitor, bloqueio de externa e abastecimento, visibilidade pela Logística, correção com autoria preservada, exclusividade do Rodrigo e cadastro pela gerência de Produção. Dados fictícios e eventos desses testes revertidos. Em produção, checagens de permissões dos usuários reais em transação revertida, sem criar registros de negócio.

Avisos legados do Supabase permanecem os documentados em DASHBOARDS.md. Sem inspeção visual em navegador real neste ambiente. Para trocar os responsáveis exclusivos no futuro, deve-se alterar a autorização no banco em migração auditável; editar somente nomes/rótulos no navegador não concede permissões.

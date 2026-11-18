# Arquivos e exportações — 18/11/2026

## Visualizar sem salvar em Downloads

Comprovantes do PDI (PDF, PNG e JPG) têm botões Visualizar e Baixar. No Caixa, os PDFs abrem em janela flutuante; gerência/Diretoria consultam os arquivos em Comprovantes dos fechamentos no dashboard, sem formulários de coleta ou edição. A janela acompanha o tema, adapta-se ao celular, fecha com Fechar/Escape e libera o endereço temporário ao sair. O PDF é buscado no Storage privado com a sessão/RLS atual, sem URL pública. O navegador recebe os bytes para exibir, mas o sistema não aciona download em disco. A renderização depende do visualizador PDF do navegador; existe opção de baixar como alternativa.

Abertura solicitada, janela aberta e falhas informadas são registradas no log do Caixa com usuário/data/arquivo. “Janela aberta” confirma a ação da aplicação; não prova que o navegador renderizou todas as páginas. Comprovantes do PDI mantêm suas permissões anteriores.

## CSV dos dados de desempenho

PCP, Caixa e Logística têm Exportar recorte em CSV e Exportar histórico completo. Em Indicadores e performance, Exportar todo o desempenho reúne apenas as áreas que o usuário pode consultar. Exportar recorte usa os filtros já aplicados na tela; alterações ainda não consultadas não mudam o recorte. Apenas perfis com acesso aos dashboards podem exportar dados operacionais, sem ampliar permissões.

A consulta não é limitada à página visível. Histórico completo ignora período/colaborador/veículo/processo e inclui registros anulados e cadastros da Logística. Recorte respeita datas, pessoa, veículo, processo e opção de anulados; na Visão Geral também inclui os cadastros correspondentes. Cadastros são atuais e não recebem filtro de data de operação. Veículo não filtra ponto; pessoa não filtra manutenção/cronograma, conforme as regras da tela. Ao ultrapassar 50.000 linhas, a operação falha explicitamente e pede divisão por período/área: não existe truncamento silencioso nem arquivo parcial.

CSV: UTF-8 com BOM, ponto e vírgula, aspas/novas linhas escapadas, proteção contra fórmulas em células de texto. Colunas modulo/processo identificam cada linha. Campos operacionais da Logística são expandidos com prefixo campo_. Valores originais em centavos são preservados e recebem colunas adicionais *_reais com vírgula decimal. Listas de pedidos e planos de parcelas são conservados em JSON. Ausente e zero permanecem diferentes. PDF é representado pelo identificador/nome, não por seu conteúdo binário. Logs/justificativas gerenciais continuam na exportação própria do log.

Cada área grava DATA_CSV_GENERATED com ator, quantidade e filtros e DATA_CSV_DOWNLOAD_TRIGGERED quando o download é acionado. Esses eventos aparecem na pesquisa mensal do Log gerencial; a aba Exportações CSV anterior continua voltada aos CSV de logs. O registro confirma acionamento, não a gravação efetiva pelo navegador.

## Equipe da Logística

Cadastros “Colaborador de outro setor” não aparecem nos seletores, listagens, totais de jornada, ranking de saldo ou CSV de desempenho individual. Movimentação, reposição e abastecimento continuam permitidos. Se a categoria de uma pessoa mudar, a consulta de jornada considera sua categoria atual. Os registros antigos não são apagados e permanecem auditáveis no log.

## Banco e validação

Migração aplicada: 20261118131600_performance_data_csv_pdf_preview_and_team_scope. Apenas funções, sem tabelas adicionais nem cópias. Leitura de exportação usa SECURITY INVOKER e RLS; a confirmação privada de download verifica evento gerado pelo próprio usuário e acesso atual. Teste com base real em transação revertida confirmou três módulos da Diretoria e confirmação de exportação; impressões digitais dos registros originais e 40 tabelas permaneceram iguais.

Testes: 117 verificações de interface, 25 de arquivos/CSV, 22 de gráficos, 46 de CSS/contraste/regras responsivas, 14 de SQL e três verificações da exclusão de Outros de listagem/dashboard/CSV de jornada. Dados fictícios só no Postgres local e com rollback. Avisos legados de segurança documentados em DASHBOARDS.md permanecem iguais. Não houve teste de renderização em navegador real neste ambiente.

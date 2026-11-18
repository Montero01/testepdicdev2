# PDI CDE conectado — 16/11/2026

Esta versão usa o projeto Supabase já existente da CDE. Não é demonstração: envios, avaliações, fotos e exclusões afetam dados reais.

## Como testar

1. Abra `pdi-conectado/index.html` no Site publicado e entre com seu e-mail e senha já cadastrados no PDI. Nenhuma conta foi criada ou senha alterada.
2. Clique no círculo ao lado do seu nome, ou em **Meu perfil → Alterar foto**. Selecione JPG, PNG ou WebP de até 5 MB; ajuste aproximação/posição e salve.
3. Em **Indicadores**, selecione as datas e clique em **Analisar**. Para os registros atuais, o mês de novembro de 2026 tem lançamentos operacionais.
4. A Diretoria abre **Acessos por área**, escolhe a pessoa responsável, a área **Financeiro** e o nível **Gerência · dashboards**. Isso libera os indicadores de Caixa para essa pessoa sem promover o nível geral em `profiles`.

O Site de teste continua privado para o proprietário. Para o acesso dos colaboradores, publique os arquivos no endereço utilizado pelo PDI ou configure conscientemente a audiência do Site. O acesso do Site é uma camada diferente do login Supabase.

## O que mudou

- Login real via Supabase Auth; SDK 2.45.4 incluído localmente.
- Foto circular com prévia e recorte local em 512 × 512 WebP, salva no bucket `avatars`; `profiles.avatar_url` continua compatível com o PDI/Academy anteriores.
- Menu lateral no computador e suspenso no celular; temas claro/escuro preservados.
- Visão geral, gestão de metas, comprovantes e ranking passam a usar os dados existentes.
- Indicadores: conclusão, atraso, envios aguardando validação, pontos por data de aprovação, comparação por setor, evolução mensal, série de m² e movimento de Caixa, conforme a autorização.
- PCP: ranking e totais consolidados no banco. Caixa: composição por forma de pagamento e movimento diário.
- Autorizações por área, independentes do nível geral do PDI; alterações registradas em log restrito à Diretoria.
- Restrição no banco para neutralizar políticas permissivas antigas, não apenas no menu.

## Acesso efetivo

| Perfil | PCP | Caixa | Operação |
| --- | --- | --- | --- |
| Diretoria/Master | Consolidado | Consolidado | Somente dashboards de desempenho |
| Gerência de Produção autorizada | Dashboard e logs | Sem acesso por ser Produção | Consulta |
| Supervisão de Produção autorizada | Dashboard e correções | Sem acesso por ser Produção | Correção com justificativa, sem logs gerenciais |
| Gerência Financeira autorizada | Sem acesso por ser Financeiro | Dashboard e logs | Consulta |
| PCP / Op. de Caixa | Próprios registros do módulo do cargo | Próprios registros do módulo do cargo | Um envio por dia; não altera após envio |
| Demais colaboradores | Sem indicadores gerenciais | Sem indicadores gerenciais | Meu PDI |

Na configuração inicial, as três contas já classificadas como gerente/supervisor de PRODUÇÃO receberam a área Produção. **Não havia conta de gerência financeira explicitamente configurada**: a pessoa com título de Gerente Administrativa tem nível geral de colaborador. Por isso, a Diretoria escolhe a responsável em **Acessos por área**. Não foi feita promoção automática por texto do cargo. ADMINISTRATIVO inteiro não recebeu acesso financeiro.

Por decisão atual, Financeiro só aceita Gerência; não foi liberada supervisão financeira. A coleta própria continua habilitada para as duas contas de Op. de Caixa. Gerência/Diretoria não criam nem corrigem lançamentos de desempenho.

As autorizações de área não concedem criação/avaliação de metas gerais. O supervisor continua sem criar metas. Novos módulos são cadastrados com `enabled=false` e coletor `none`; formulário, validação e indicadores precisam ser implementados antes da ativação. Não basta adicionar um cargo para criar automaticamente um formulário.

## Critérios dos indicadores

- Todas as consultas aplicam RLS e validam a autorização no servidor.
- Metas do painel são selecionadas pelo prazo. Conclusão = metas distintas com comprovante aprovado / metas com prazo no período. Sem denominador, mostra “—”.
- Atraso = prazo anterior ao dia atual em Manaus e ausência de aprovação. Pode incluir um envio ainda pendente de avaliação.
- Pontos = pontos dos comprovantes aprovados, selecionados pela data de validação. As metas do recorte e os pontos do recorte usam datas diferentes e são identificados no painel.
- Aderência da visão geral = comprovantes aprovados / comprovantes analisados (aprovados + rejeitados). Não representa o percentual de metas concluídas.
- Coeficiente = pontos aprovados / pontos máximos das metas, sem inventar uma meta financeira ou de produtividade.
- Ranking PCP = soma dos m² registrados no período; empates compartilham posição. Precisão no banco de até três casas decimais.
- Caixa armazena centavos inteiros, confere a soma das formas de pagamento e valida os parcelamentos. Crédito parcelado entra pelo valor integral informado; esse painel não é extrato bancário, fluxo de recebimento de parcelas ou lucro.
- Média diária operacional = total / dias com registro. Não é média por dia útil nem indicador de presença.
- Gráficos diários passam a agrupar por mês quando há mais de 31 dias com registro; totais vêm de agregação SQL, sem corte do limite de linhas REST.
- Registros operacionais aparecem com as correções consideradas. Auditoria preserva valores anteriores, ator, justificativa, área e nível de responsabilidade.

## Dados e privacidade

A chave incluída em `dados-reais.js` é **publishable**; não é chave privilegiada. Nenhuma service-role key está no pacote. As regras de acesso estão no Supabase. Senhas não são salvas pelo código da aplicação; o SDK mantém a sessão no navegador e o tema usa localStorage. Nenhuma planilha ou base real foi incorporada ao código estático.

O bucket `avatars` já era público. Essa compatibilidade foi preservada: quem tiver uma URL de foto poderá vê-la. Upload, alteração e exclusão no Storage são restritos à pasta do próprio usuário. Comprovantes e PDFs do Caixa continuam privados, com autorização para download.

## Instalação e banco

Publique `index.html`, `modelo.js`, `modelo.css`, `tema.js`, `dados-reais.js` e a pasta `assets` juntos em uma hospedagem HTTPS. O arquivo deve ser servido por HTTP(S), não aberto com `file://`.

As migrações `01-areas.sql` até `05-anexos.sql` **já foram aplicadas ao projeto conectado**; não é necessário executá-las novamente. Algumas criações de políticas/triggers são de execução única. Elas dependem das tabelas e módulos PCP/Caixa já instalados no projeto; não são um instalador de Supabase vazio. O histórico correspondente está em Supabase Migrations.

Foram preservados os 32 perfis, 14 metas, três certificados e os dois lançamentos operacionais existentes. Não foram criados lançamentos fictícios na produção nem alteradas senhas.

## Verificação

- 80 verificações iniciais em PostgreSQL local fictício: áreas, permissões, revogação, dashboards, correções, auditoria e fotos.
- 24 testes adicionais de metas, certificados, concorrência de validação e comprovação de titularidade de arquivos.
- 60 verificações de interface/adaptador com API local simulada.
- 44 verificações de sintaxe CSS, contraste e regras responsivas.
- Verificação por transação revertida das permissões dos 32 perfis reais e conferência da preservação dos registros.

Não houve teste visual em navegador nem login/upload com credenciais reais de um colaborador nesta execução. A validação de ponta a ponta deve ser concluída entrando com sua conta no link publicado. Avisos legados do Supabase sobre `recalculate_supervisor_goals`, RPCs antigas e proteção de senhas vazadas são anteriores a esta entrega; esta alteração não é uma auditoria integral de todos os módulos do projeto.

## Trocar senha — atualização de 17/11/2026

Em **Meu perfil → Segurança da conta → Trocar senha**, informe a senha atual, a nova senha (mínimo de 8 caracteres) e a confirmação. O Supabase valida a senha atual mediante login recente e aplica a troca à própria conta com `auth.updateUser`. Não é uma redefinição administrativa de outras contas. As senhas não são gravadas em `profiles`, logs da aplicação ou localStorage pelo formulário. Não é preciso executar SQL ou alterar permissões para habilitar essa função. A senha alterada vale para os demais aplicativos que usam a mesma conta Supabase, inclusive o Academy se compartilhar esse login.


## PCP: analisado, salvo, desperdício e aproveitamento — 17/11/2026

A atualização já está aplicada no Supabase conectado. A migração registrada é `20261117122911_pcp_analyzed_area_waste_and_efficiency`; o SQL incluído é uma cópia para consulta e outros ambientes com as mesmas dependências, e não deve ser executado novamente neste projeto.

- O PCP informa **M² Analisado**, **M² Salvo** e os pedidos do dia. São até três casas decimais, um lançamento por PCP/dia, como antes. Ambos os valores são obrigatórios nos novos envios. Se houver área analisada ou salva, os pedidos são obrigatórios.
- A supervisão de Produção continua corrigindo esses campos com justificativa. A gerência não passa a editar o informado pelo PCP.
- **Supervisão e gerência de Produção autorizadas** podem registrar ou corrigir **M² Desperdiçado**, associando o registro ao lançamento existente do PCP e ao dia. Use os filtros por PCP e data e abra **Registrar desperdício por PCP**. A Diretoria mantém consulta consolidada; não lança desperdício. Gerência financeira/comercial sem área Produção não ganha acesso.
- O desperdício está em tabela separada com RLS. O PCP não consegue gravá-lo mesmo chamando a API diretamente. Inserções e correções são auditadas; correções exigem justificativa e usam revisão para evitar sobrescrever alterações de outra pessoa. Logs completos ficam para gerência de Produção/Diretoria, como antes.
- **M² salvos + m² desperdiçados não podem superar m² analisados.** Salvos são recuperação dentro da área analisada; não são somados outra vez ao total útil.

### Cálculos

| Indicador | Fórmula |
| --- | --- |
| Aproveitamento | `(analisado − desperdiçado) / analisado × 100` |
| Desperdício | `desperdiçado / analisado × 100` |
| Recuperação | `salvo / analisado × 100` |

Exemplo: 100 m² analisados, 20 m² salvos e 10 m² desperdiçados resultam em 90% de aproveitamento, 10% de desperdício e 20% de recuperação. A relação analisado/desperdiçado invertida não é usada como percentual de perda.

No período, os percentuais são calculados sobre somas, **não pela média simples dos percentuais diários**. O resumo de aproveitamento/desperdício usa pares com ambos os dados; a contagem de pendências fica visível. Base analisada zero mostra “—”. Ausência de desperdício não vira zero: é necessário confirmar zero explicitamente.

O ranking de aproveitamento inclui apenas PCPs com todos os lançamentos do recorte preenchidos e base analisada positiva. Há também gráficos em barras por total analisado, total salvo e total desperdiçado. No último, valores maiores aparecem no topo em destaque negativo. O volume perdido deve ser comparado ao analisado e à taxa percentual, sem concluir culpa só pela classificação.

Os registros anteriores foram preservados com analisado “não informado”. A supervisão precisa completar esse campo para avaliar aproveitamento ou registrar desperdício nesses dias. A cópia do dashboard antigo continua disponível no histórico do Site, mas versões antigas do formulário precisam ser atualizadas para enviar o novo campo obrigatório.

A nova função foi verificada com 43 testes PostgreSQL locais, 60 testes de interface/adaptador com API simulada e 44 verificações de CSS. Os 32 perfis reais foram verificados em transação revertida. Não foram criados dados fictícios na produção; o lançamento antigo foi conferido por impressão digital e permaneceu intacto. Não houve teste visual em navegador autenticado.

Os modelos para trocar a senha de uma ou várias contas estão em `administracao/alterar-senhas.sql`. Eles não foram executados na produção. Bcrypt foi validado somente em contas fictícias no PostgreSQL local. O uso administrativo de SQL não substitui o gerenciamento de sessões do Supabase Auth.


## Log gerencial mensal, pesquisa e CSV — 17/11/2026

Disponível no **Log de auditoria** do PCP e no **Log do Caixa**, para a gerência da respectiva área e a Diretoria. As permissões da supervisão e dos colaboradores não foram ampliadas.

- O bloco começa recolhido. Abra-o para carregar somente uma página do mês atual, sem carregar todo o histórico.
- **Pesquisar registros:** consulta por usuário, e-mail, UUID, pedido, ação, valores ou justificativa. O mês considera quando o evento ocorreu, no horário de Manaus; o dia do lançamento fica identificado separadamente. A página traz até 30 eventos.
- **Arquivos mensais:** escolha o mês e clique em **Baixar CSV**. Consultas a meses anteriores em Pesquisar também produzem o CSV em vez de uma lista extensa.
- **Exportar CSV:** exporta todos os resultados do mês/pesquisa/colaborador selecionados, sem se limitar à página visível. Exportações acima de 50 mil eventos exigem refinar os filtros e não são truncadas silenciosamente.
- **Exportações CSV:** histórico por mês de referência do arquivo, com nome, e-mail, ID do usuário, horário, filtros, colaborador selecionado e quantidade de eventos. Não há edição ou exclusão desse histórico pelo aplicativo.
- A geração do CSV é registrada no servidor antes de o conteúdo ser devolvido ao navegador. O acionamento do download é confirmado por uma segunda chamada, somente pelo próprio usuário exportador. O navegador não informa se o arquivo foi efetivamente salvo no dispositivo; por isso o histórico não afirma “download concluído”.
- Eventos antigos mantêm o nome/nível original do autor e seu UUID, quando disponíveis. O e-mail mostrado nos eventos é o e-mail atual no cadastro; nas novas exportações, é salvo um retrato do e-mail e nome na geração. Operações administrativas sem usuário autenticado são identificadas pela origem de banco, sem atribuir um autor fictício.
- O CSV tem UTF-8 com BOM, separador `;`, campos entre aspas, data UTC e Manaus, autor, antes/depois em JSON e justificativa. Conteúdo que poderia ser interpretado como fórmula é neutralizado para leitura em planilhas.
- Cores dos detalhes, JSON e painéis internos seguem o tema ativo, corrigindo texto claro sobre fundo branco no modo escuro.

A migração `20261117130144_managerial_audit_monthly_search_csv_tracking` já foi aplicada no projeto conectado. Não execute novamente a cópia SQL incluída neste pacote. Nenhum evento real foi removido nem arquivado fora do banco: os meses anteriores continuam disponíveis para download. As verificações na produção foram feitas em transação revertida, sem deixar exportações fictícias registradas.

Verificação desta atualização: 31 testes SQL locais; 73 verificações de interface/adaptador com API simulada; 46 verificações CSS/contraste/regras responsivas. Consultas e geração/registro do CSV foram verificados no Supabase real em transação revertida. Não houve conferência visual em navegador autenticado nesta execução.

## Revisão integrada dos processos de desempenho

A versão mais recente amplia o mesmo log mensal para os eventos dos PDFs, consultas dos indicadores, CSV, configurações e autorizações, preservando o isolamento por área. Também corrige histórico de desperdício em páginas diferentes, comparação de áreas decimais, navegação durante operações e agrupamento de pontos no horário de Manaus. Consulte `REVISAO-DESEMPENHO.md` para cobertura, correções, testes e limites de verificação.

## Novo módulo de Logística

Acesse **Desempenho → Logística**. O módulo reúne Visão Geral, movimentações, reposições, jornadas individuais, manutenções, cronograma, abastecimentos, log mensal e cadastros de equipe/frota. Consulte `LOGISTICA.md` para o passo a passo inicial, permissões, campos e fórmulas. A base está vazia de lançamentos logísticos; o primeiro passo da Diretoria é cadastrar a equipe e os veículos e atribuir os responsáveis pela área.

Dashboards setorizados: consulte DASHBOARDS.md para gráficos, filtros, cálculos e validação.

Visualização de comprovantes e exportação dos dados: consulte ARQUIVOS-E-EXPORTACOES.md.

Estoque e permissões específicas: consulte ESTOQUE-E-ACESSOS.md.

Gestão de exclusões, orçamento da frota e eficiência do Estoque: GESTAO-E-EFICIENCIA.md.

Continuidade do orçamento de combustível e projeções: ORCAMENTO-COMBUSTIVEL.md.

Exclusão agora nos ajustes de cada registro: EXCLUSAO-NOS-AJUSTES.md.

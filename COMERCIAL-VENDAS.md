# Comercial · Vendas — 19/11/2026

O módulo usa o menu, login, temas, cartões, filtros, abas, controles de ajustes e motor de gráficos do PDI. Não tem seletor de usuários fictícios ou armazenamento de indicadores no navegador.

Acesse Desempenho → Comercial · Vendas. Coordenação/gerência deve abrir Regras da campanha e definir datas, metas e pontos. As datas não foram presumidas. Bitrix24 mantém 1 ponto por dia de uso; demais critérios só pontuam se ativados. Todas as mudanças de configuração geram log e recalculam a campanha.

Participantes por `profiles.position`: Consultor(a) de Vendas e Coordenadora Comercial. Vendedor registra e consulta os próprios dados; coordenadora, gerências e Diretoria acompanham todos e podem registrar em nome de participantes, ajustar e excluir com justificativa. A autorização da coordenadora é exclusiva do Comercial; não altera seu role nem permissões dos outros setores.

Um registro ativo por participante/dia. Data até hoje e dentro da campanha. Dinheiro em centavos e áreas em milésimos de m². Conversão e ticket usam totais do recorte, sem média de percentuais diários. Conversão sem orçamento e ticket sem vendas ficam sem base (—). Habitat/Laminado podem se sobrepor e são validados individualmente contra o total.

Novos clientes: um por linha, `Nome | código opcional`. Quantidade calculada a partir da identificação. No acumulado, duplicações são removidas por código ou nome normalizado dentro de cada participante; a existência de compras anteriores no ERP não é validada. A soma da equipe é de clientes atribuídos aos participantes, não uma contagem global validada de pessoas únicas.

Pontuação: indicadores positivos = pontos × mínimo(resultado/meta,1). Reposições = −penalidade × resultado/referência, sem teto. Ativar simultaneamente quantidade/R$/m² acumula penalidades. Valores de meta/referência são expressos em R$ ou m². Desempates: Bitrix, conversão, menos erros em quantidade, maior ticket. Empates integrais compartilham posição; sem lançamentos não participa do ranking. Pontuação calculada em quatro casas, exibida em até duas.

Filtros por período e participante, quatro gráficos expansivos (+/−): barras com seleção de indicadores, pizza de quantidade sem desconto/demais, evolução/tendência diária e dispersão orçamentos/vendas. Memória de cálculo no ranking. Exclusão dentro do ajuste, sem uma aba separada. Justificativa obrigatória, versão do registro e da campanha para detectar alterações concorrentes.

Mesmo projeto Supabase e auditoria compartilhada: `pdi_sales_campaigns` (regras) e `pdi_sales_daily` (lançamentos). Não há tabela por gráfico ou vendedor. As tabelas têm RLS e não aceitam gravação direta de authenticated; as operações passam por funções validadas no servidor. Identidade vem de auth.uid(). Exclusão lógica mantém o histórico em `pdi_performance_events`.

CSV de lançamentos respeita acesso/período/participante. Log com pesquisa, consulta mensal, antes/depois, usuário e exportação; meses anteriores são consultados via CSV. Solicitações de exportação também são auditadas. Limite de 50 mil registros/eventos por consulta/exportação, com erro explícito para refinar o período. O CSV contém registros diários; indicadores consolidados deduplicam clientes no recorte.

Validação: 46 verificações SQL locais com perfis fictícios (permissões, RLS, anonimato, unicidade, concorrência, validações, exclusões e auditoria); teste DOM do Comercial; 18 verificações de cálculos; testes existentes do PDI (169 interface, 46 CSS, 126 expansões, 22 gráficos, 25 arquivos). Na produção foram verificados a estrutura, os acessos calculados dos perfis e a ausência de lançamentos de teste. Sem inspeção visual em navegador ou login real nesta sessão, por indisponibilidade do controle de navegador no ambiente.

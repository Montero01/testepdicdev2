# Padrão visual de ajustes e expansões — 18/11/2026

Todos os ajustes de registros usam o mesmo componente `adjustmentGroup`: o resumo nativo de um details, com as mesmas classes, dimensões, posição do sinal, fundo e borda. Gerência abre ações autorizadas de exclusão; supervisão abre os formulários autorizados de edição. Permissões existentes continuam determinando o conteúdo. PCP, Caixa, Logística, Estoque, cadastros e conferências de desperdício usam a apresentação comum.

Controle fechado mostra +; aberto mostra −. A regra cobre os painéis de indicadores, gráficos, tabelas de dados, logs, anexos, parcelamentos, exportações e ajustes, nos temas claro/escuro. Marcadores nativos de triângulo são ocultados em Chromium, Firefox e Safari. O submenu Desempenho também usa +/− conforme aria-expanded. Ícones de navegação e do menu móvel mantêm suas funções.

O componente editor usa o comportamento nativo de details/summary, compatível com teclado. Abrir um ajuste de edição fecha e limpa o anterior, evitando formulários e identificadores duplicados. Fechar o ajuste descarta o formulário ainda não enviado. Formulários de edição não concedem permissão de exclusão; o controle gerencial continua validado no servidor. Abertura de ajuste de cadastro existente cancela o formulário de cadastro novo ainda aberto, conforme o fluxo anterior de edição exclusiva.

Controle Ajustes tem 40 px de altura mínima no desktop e 44 px no celular, com símbolo de expansão alinhado à direita. O restante da marca, os dados, os cálculos e a base Supabase não foram alterados.

Validação: 169 verificações de interface, incluindo identidade do elemento/classes entre gerência e supervisão, edição autorizada, fechamento de editores concorrentes e bloqueio de exclusão para supervisão. Mais 126 verificações específicas de cascata/símbolos/estilo em claro/escuro nas larguras 390, 768 e 1440 px; 46 verificações gerais de CSS/contraste/responsividade, 25 de arquivos e 22 de gráficos. Sem renderização em navegador real neste ambiente.

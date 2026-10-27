-- Carga inicial do catálogo. Roda UMA vez, em banco vazio, como qualquer
-- migration: depois disso o catálogo vive só no banco e muda pela API admin
-- (/api/admin/products). A aplicação nunca lê este arquivo.
--
-- Títulos e autores são reais; preço e estoque são fictícios, escolhidos para
-- exercitar desconto, baixa de estoque e rejeição por falta de estoque.

INSERT INTO products
    (product_id, title, author, category, original_year, price_cents, stock, tagline, description)
VALUES
('BK001', 'Dom Casmurro', 'Machado de Assis', 'clássico', 1899, 3990, 15,
 $d$Bentinho narra seu ciúme por Capitu em um dos maiores romances brasileiros.$d$,
 $d$Já velho e recluso, Bento Santiago decide "atar as duas pontas da vida" e conta a própria história: o amor de infância por Capitu, a vizinha de "olhos de ressaca", o seminário que a mãe lhe impôs, o casamento e a amizade com Escobar. Pouco a pouco, a narrativa se transforma em acusação, e o leitor percebe que só conhece a versão de um narrador ferido. Mais de um século depois, a pergunta continua aberta: Capitu traiu ou não traiu?$d$),

('BK002', 'Memórias Póstumas de Brás Cubas', 'Machado de Assis', 'clássico', 1881, 4290, 8,
 $d$Um defunto autor narra a própria vida com ironia implacável.$d$,
 $d$"Ao verme que primeiro roeu as frias carnes do meu cadáver": assim começa o livro que inaugurou o Realismo no Brasil. Livre de qualquer compromisso depois de morto, Brás Cubas revisita uma vida de privilégios, amores mal resolvidos e projetos abandonados, conversando com o leitor em capítulos curtos e imprevisíveis. O resultado é um retrato mordaz da elite do Segundo Reinado e uma das obras mais modernas da língua portuguesa.$d$),

('BK003', 'Grande Sertão: Veredas', 'João Guimarães Rosa', 'clássico', 1956, 6990, 20,
 $d$A travessia de Riobaldo pelo sertão e pela linguagem.$d$,
 $d$Ex-jagunço, Riobaldo conta a um visitante silencioso as guerras entre bandos no sertão mineiro, o pacto que talvez tenha feito com o diabo e o amor inconfessável por Diadorim. Em um monólogo contínuo, Guimarães Rosa reinventa a língua a partir da fala sertaneja e transforma a travessia geográfica em uma investigação sobre o bem, o mal e o destino. "Viver é muito perigoso."$d$),

('BK004', 'Vidas Secas', 'Graciliano Ramos', 'clássico', 1938, 3490, 3,
 $d$A seca e a migração de Fabiano e sua família pelo sertão.$d$,
 $d$Fabiano, sinha Vitória, os dois meninos e a cachorra Baleia fogem da seca e se abrigam em uma fazenda abandonada, onde vivem de trabalho mal pago e humilhações. Em capítulos que funcionam quase como contos, Graciliano Ramos usa uma prosa seca como a paisagem para mostrar personagens que mal conseguem pôr em palavras o que sentem. Um romance curto, duro e inesquecível sobre miséria, dignidade e silêncio.$d$),

('BK005', 'Capitães da Areia', 'Jorge Amado', 'clássico', 1937, 3790, 5,
 $d$Meninos de rua em Salvador nos anos 1930.$d$,
 $d$Em um trapiche abandonado no cais de Salvador vive um bando de meninos que sobrevive de pequenos furtos: Pedro Bala, o líder; Professor, que lê e desenha; Sem-Pernas, cheio de rancor; Pirulito, que sonha com a fé. A chegada de Dora, a única menina do grupo, muda tudo. Proibido e queimado em praça pública na época do lançamento, o romance de Jorge Amado segue atual como denúncia do abandono da infância.$d$),

('BK006', 'A Hora da Estrela', 'Clarice Lispector', 'clássico', 1977, 3290, 5,
 $d$Macabéa, a nordestina invisível da cidade grande.$d$,
 $d$Rodrigo S.M., um narrador inquieto, tenta contar a história de Macabéa, datilógrafa alagoana que vive no Rio de Janeiro sem saber que é infeliz. Ela come cachorro-quente, ouve a Rádio Relógio e namora Olímpico, que a despreza. Último livro publicado em vida por Clarice Lispector, é ao mesmo tempo uma narrativa sobre a pobreza e uma reflexão sobre o próprio ato de escrever.$d$),

('BK007', 'A Paixão Segundo G.H.', 'Clarice Lispector', 'clássico', 1964, 3890, 15,
 $d$Uma crise existencial a partir de um encontro banal.$d$,
 $d$Uma escultora de classe média alta decide arrumar o quarto da empregada que acabou de ir embora. Lá dentro, diante de uma barata presa na porta do armário, G.H. atravessa uma experiência que desmonta sua identidade, sua linguagem e sua ideia de humanidade. Narrado em fluxo de consciência, é considerado por muitos críticos o romance mais radical de Clarice Lispector.$d$),

('BK008', 'O Cortiço', 'Aluísio Azevedo', 'clássico', 1890, 2990, 3,
 $d$Naturalismo e vida coletiva em um cortiço carioca.$d$,
 $d$O português João Romão enriquece explorando os moradores do cortiço que construiu em Botafogo, enquanto o vizinho Miranda, comerciante de sobrado, observa com desprezo e inveja. Entre lavadeiras, operários, brigas e paixões, o próprio cortiço parece um organismo vivo. Principal romance do Naturalismo brasileiro, mostra como o ambiente e a ambição moldam o destino das pessoas no Rio do século XIX.$d$),

('BK009', 'Iracema', 'José de Alencar', 'clássico', 1865, 2590, 10,
 $d$Lenda romântica da fundação do Ceará.$d$,
 $d$Iracema, "a virgem dos lábios de mel", guarda o segredo da jurema da tribo tabajara. Ao se apaixonar pelo guerreiro português Martim, ela rompe com seu povo, e dessa união nasce Moacir, o "filho da dor", símbolo do primeiro cearense. Com prosa poética e cheia de imagens da natureza, José de Alencar escreveu um dos pilares do indianismo romântico e um mito de origem do Brasil.$d$),

('BK010', 'Macunaíma', 'Mário de Andrade', 'clássico', 1928, 3690, 3,
 $d$A rapsódia modernista do herói sem nenhum caráter.$d$,
 $d$Nascido no fundo da mata virgem, Macunaíma é preguiçoso, mentiroso, sensual e irresistível. Ao perder a muiraquitã, seu amuleto, ele vai a São Paulo enfrentar o gigante Piaimã, em uma aventura que mistura lendas indígenas, cultura popular e sátira da vida urbana. Obra central do Modernismo, a "rapsódia" de Mário de Andrade é uma tentativa bem-humorada de compor o retrato de um Brasil sem caráter definido.$d$),

('BK011', 'Cem Anos de Solidão', 'Gabriel García Márquez', 'ficção', 1967, 6490, 5,
 $d$A saga dos Buendía em Macondo, marco do realismo mágico.$d$,
 $d$José Arcadio Buendía funda Macondo no meio do pântano, e por sete gerações sua família repete nomes, obsessões e solidões enquanto a cidade vive guerras civis, a febre da companhia bananeira e chuvas que duram anos. Tapetes voam, mortos voltam para conversar e ninguém se espanta. A obra-prima de García Márquez é um épico sobre a América Latina e sobre a memória que se apaga.$d$),

('BK012', 'O Amor nos Tempos do Cólera', 'Gabriel García Márquez', 'ficção', 1985, 5790, 20,
 $d$Um amor que atravessa cinco décadas de espera.$d$,
 $d$Florentino Ariza se apaixona por Fermina Daza na juventude, mas ela se casa com o médico Juvenal Urbino. Florentino decide esperar, e espera por cinquenta e um anos, nove meses e quatro dias. Ambientado em uma cidade caribenha às voltas com epidemias de cólera, o romance é uma reflexão terna e irônica sobre o amor em todas as idades, inclusive na velhice.$d$),

('BK013', 'A Casa dos Espíritos', 'Isabel Allende', 'ficção', 1982, 5490, 20,
 $d$Três gerações de uma família e a história do Chile.$d$,
 $d$Clara, que conversa com espíritos e prevê o futuro, casa-se com o temperamental Esteban Trueba, patriarca conservador. A história da família, das filhas e das netas acompanha meio século de um país latino-americano que lembra o Chile, até o golpe militar. Romance de estreia de Isabel Allende, combina realismo mágico, crônica política e uma linhagem de mulheres fortes.$d$),

('BK014', 'Ensaio sobre a Cegueira', 'José Saramago', 'ficção', 1995, 5290, 5,
 $d$Uma epidemia de cegueira branca desmonta a civilização.$d$,
 $d$Um homem fica cego de repente, parado no semáforo, e a "cegueira branca" se espalha por toda a cidade. Os primeiros contaminados são confinados em um manicômio abandonado, onde a ordem social se desfaz em poucos dias. Só a mulher do médico continua enxergando. Com a pontuação peculiar de Saramago, o romance é uma alegoria poderosa sobre solidariedade, violência e o que resta de humano em situações extremas.$d$),

('BK015', 'O Evangelho Segundo Jesus Cristo', 'José Saramago', 'ficção', 1991, 5590, 10,
 $d$Releitura humanizada da vida de Jesus.$d$,
 $d$Saramago reconta a vida de Jesus de Nazaré como a de um homem: o filho de um carpinteiro atormentado pela culpa, o jovem que aprende com Maria Madalena, o pregador que dialoga com Deus e com o Diabo e questiona o preço do próprio destino. Polêmico desde o lançamento, o livro é uma meditação sobre fé, culpa e poder, escrita com a ironia e a compaixão típicas do autor.$d$),

('BK016', '1984', 'George Orwell', 'ficção', 1949, 4790, 5,
 $d$Vigilância total e reescrita do passado na Oceania.$d$,
 $d$Na Oceania, o Grande Irmão observa tudo, a língua oficial é reduzida para impedir o pensamento e o passado é reescrito todos os dias. Winston Smith trabalha justamente falsificando registros no Ministério da Verdade, até começar um diário secreto e um romance proibido com Julia. O clássico de Orwell deu ao mundo expressões como "duplipensar" e "Big Brother" e continua sendo a referência quando se fala em vigilância e manipulação.$d$),

('BK017', 'A Revolução dos Bichos', 'George Orwell', 'ficção', 1945, 2990, 20,
 $d$Fábula política sobre a corrupção de uma revolução.$d$,
 $d$Cansados da exploração do fazendeiro Jones, os animais da Granja do Solar se rebelam e criam uma sociedade em que "todos os bichos são iguais". Aos poucos, os porcos assumem o comando, reescrevem os mandamentos e se tornam indistinguíveis dos antigos donos. Curta e acessível, a fábula de Orwell é uma sátira do stalinismo e uma lição atemporal sobre como o poder corrompe ideais.$d$),

('BK018', 'Admirável Mundo Novo', 'Aldous Huxley', 'ficção', 1932, 4590, 3,
 $d$Uma distopia de prazer programado e castas genéticas.$d$,
 $d$No Estado Mundial, os bebês são produzidos em laboratório e condicionados para pertencer a castas, o sexo é recreação, a família foi abolida e o soma garante felicidade sem efeitos colaterais. Quando Bernard Marx traz de uma reserva o "Selvagem" John, criado lendo Shakespeare, o choque expõe o preço da estabilidade perfeita. Ao lado de 1984, é uma das distopias mais influentes do século XX.$d$),

('BK019', 'Fahrenheit 451', 'Ray Bradbury', 'ficção', 1953, 4190, 5,
 $d$Bombeiros que queimam livros em uma sociedade anestesiada.$d$,
 $d$Guy Montag é bombeiro, e em seu mundo bombeiros não apagam incêndios: queimam livros, proibidos por perturbarem a paz. Enquanto a esposa vive hipnotizada por telas que ocupam paredes inteiras, um encontro com a jovem Clarisse faz Montag começar a questionar tudo e a esconder livros em casa. A 451 graus Fahrenheit o papel pega fogo; o romance de Bradbury continua incendiando debates sobre censura e alienação.$d$),

('BK020', 'O Conto da Aia', 'Margaret Atwood', 'ficção', 1985, 4890, 10,
 $d$Teocracia e controle reprodutivo em Gilead.$d$,
 $d$Em Gilead, uma teocracia que tomou o lugar dos Estados Unidos, as poucas mulheres férteis são obrigadas a servir como aias, gerando filhos para a elite. Offred, nome que significa apenas "de Fred", narra seu cotidiano de vigilância enquanto relembra a vida que tinha antes, com marido, filha e um emprego. O romance de Margaret Atwood virou símbolo da luta pelos direitos das mulheres e inspirou uma série premiada.$d$),

('BK021', 'Crime e Castigo', 'Fiódor Dostoiévski', 'clássico', 1866, 6290, 3,
 $d$Raskólnikov e o peso moral de um assassinato.$d$,
 $d$Raskólnikov, ex-estudante miserável em São Petersburgo, convence-se de que homens extraordinários têm o direito de transgredir a lei e mata uma velha agiota. O crime é só o começo: o romance acompanha a febre, a paranoia e a culpa que o consomem, o jogo de gato e rato com o investigador Porfíri e a relação com Sônia, que lhe oferece um caminho de redenção. Um dos grandes romances psicológicos de todos os tempos.$d$),

('BK022', 'Os Irmãos Karamázov', 'Fiódor Dostoiévski', 'clássico', 1880, 7490, 20,
 $d$Fé, dúvida e parricídio em uma família russa.$d$,
 $d$O devasso Fiódor Karamázov é assassinado, e as suspeitas recaem sobre os filhos: o impulsivo Dmítri, o intelectual Ivan, o religioso Aliócha e o enigmático Smerdiakóv. Mais que um romance policial, o último livro de Dostoiévski é um debate monumental sobre Deus, liberdade e responsabilidade, que inclui o célebre capítulo do "Grande Inquisidor".$d$),

('BK023', 'Anna Kariênina', 'Liev Tolstói', 'clássico', 1878, 6890, 3,
 $d$Paixão e convenção social na Rússia imperial.$d$,
 $d$"Todas as famílias felizes se parecem." Anna, casada com um alto funcionário de São Petersburgo, apaixona-se pelo conde Vronski e desafia uma sociedade que perdoa a hipocrisia, mas não a sinceridade. Em paralelo, Liévin busca sentido para a vida no trabalho no campo e no casamento com Kitty. Tolstói constrói um panorama riquíssimo da Rússia do século XIX e um dos retratos femininos mais marcantes da literatura.$d$),

('BK024', 'O Pequeno Príncipe', 'Antoine de Saint-Exupéry', 'infantil', 1943, 2490, 10,
 $d$O encontro de um piloto com um príncipe de outro planeta.$d$,
 $d$Um aviador cai no deserto do Saara e encontra um menino de cabelos dourados que veio do asteroide B-612, onde deixou uma rosa vaidosa e três vulcões. Ao contar suas viagens por planetas habitados por adultos estranhos, o pequeno príncipe ensina sobre amizade, perda e o que é essencial e "invisível aos olhos". Ilustrado pelo próprio autor, é um dos livros mais traduzidos do mundo, para crianças e adultos.$d$),

('BK025', 'O Hobbit', 'J.R.R. Tolkien', 'fantasia', 1937, 5290, 3,
 $d$Bilbo Bolseiro parte em uma jornada inesperada.$d$,
 $d$Bilbo Bolseiro gosta de chá, conforto e nada de aventuras, até que o mago Gandalf e treze anões batem à sua porta. Eles querem recuperar o tesouro tomado pelo dragão Smaug, e Bilbo é recrutado como ladrão. No caminho há trolls, elfos, aranhas gigantes e um anel encontrado em uma caverna escura. A porta de entrada para a Terra-média continua sendo uma das melhores histórias de aventura já escritas.$d$),

('BK026', 'O Senhor dos Anéis: A Sociedade do Anel', 'J.R.R. Tolkien', 'fantasia', 1954, 7990, 8,
 $d$A formação da sociedade que levará o Um Anel a Mordor.$d$,
 $d$O anel que Bilbo trouxe de sua aventura é o Um Anel, forjado por Sauron para dominar a Terra-média. Cabe a Frodo, seu sobrinho, levá-lo até Mordor para destruí-lo, acompanhado por hobbits, um mago, um elfo, um anão e dois homens. O primeiro volume da trilogia de Tolkien constrói um mundo com línguas, mapas e história próprios e definiu a fantasia moderna.$d$),

('BK027', 'Harry Potter e a Pedra Filosofal', 'J.K. Rowling', 'fantasia', 1997, 4990, 12,
 $d$Um órfão descobre que é bruxo e vai para Hogwarts.$d$,
 $d$Harry vive no armário debaixo da escada da casa dos tios até que, no seu aniversário de onze anos, descobre que é bruxo e que tem uma vaga na Escola de Magia e Bruxaria de Hogwarts. Lá ele faz amizade com Rony e Hermione, aprende quadribol e descobre que alguém está atrás de um objeto escondido no castelo. O primeiro volume da série que formou uma geração inteira de leitores.$d$),

('BK028', 'O Nome do Vento', 'Patrick Rothfuss', 'fantasia', 2007, 5990, 20,
 $d$Kvothe narra como se tornou uma lenda.$d$,
 $d$Em uma estalagem perdida no interior, o discreto Kote é reconhecido por um cronista: na verdade ele é Kvothe, o arcanista, músico e matador de reis sobre quem se contam mil histórias. Durante três dias ele conta a verdade, começando pela infância em uma trupe de artistas, a tragédia que o deixou sozinho e a entrada precoce na Universidade. Primeiro volume da Crônica do Matador do Rei, famoso pela prosa musical.$d$),

('BK029', 'Duna', 'Frank Herbert', 'ficção', 1965, 6790, 8,
 $d$Política, religião e especiaria no planeta Arrakis.$d$,
 $d$Arrakis é um planeta desértico, cheio de vermes gigantes, e a única fonte da especiaria melange, a substância mais valiosa do universo. Quando a Casa Atreides assume o controle do planeta, cai em uma armadilha da Casa Harkonnen, e o jovem Paul precisa sobreviver entre os fremen do deserto. Considerado o maior romance de ficção científica de todos os tempos, Duna mistura ecologia, religião, política e profecia.$d$),

('BK030', 'Neuromancer', 'William Gibson', 'ficção', 1984, 4990, 5,
 $d$O romance que definiu o cyberpunk.$d$,
 $d$Case era um dos melhores hackers do mundo até ter o sistema nervoso danificado como punição por roubar o patrão. Em Chiba, no Japão, ele recebe uma proposta de cura em troca de um último trabalho, ao lado da mercenária Molly, a serviço de um contratante misterioso. Foi aqui que William Gibson popularizou o termo "ciberespaço"; o livro venceu os prêmios Hugo, Nebula e Philip K. Dick.$d$),

('BK031', 'Sapiens', 'Yuval Noah Harari', 'não-ficção', 2011, 6990, 12,
 $d$Uma breve história da humanidade.$d$,
 $d$Como uma espécie de primata sem importância passou a dominar o planeta? Harari percorre três revoluções, a cognitiva, a agrícola e a científica, para explicar como mitos compartilhados, como dinheiro, religiões, nações e empresas, permitiram a cooperação de milhões de desconhecidos. Um livro de divulgação provocador, que convida a repensar o progresso e a felicidade humana.$d$),

('BK032', 'Rápido e Devagar', 'Daniel Kahneman', 'não-ficção', 2011, 7290, 8,
 $d$Os dois sistemas que governam nosso pensamento.$d$,
 $d$Prêmio Nobel de Economia, Daniel Kahneman apresenta duas formas de pensar: o Sistema 1, rápido, intuitivo e emocional, e o Sistema 2, lento, deliberado e lógico. A partir de décadas de experimentos, ele mostra como vieses como ancoragem, aversão à perda e excesso de confiança afetam decisões no trabalho, nos investimentos e na vida pessoal. Leitura de referência em psicologia e economia comportamental.$d$),

('BK033', 'O Gene', 'Siddhartha Mukherjee', 'não-ficção', 2016, 7890, 5,
 $d$A história íntima da genética.$d$,
 $d$Das ervilhas de Mendel ao sequenciamento do genoma humano e à edição com CRISPR, Siddhartha Mukherjee conta a história de uma das ideias mais poderosas da ciência. Médico e vencedor do Pulitzer, ele entrelaça a narrativa científica com a história da própria família, marcada por doenças mentais, e discute os dilemas éticos de podermos ler e reescrever o código da vida.$d$),

('BK034', 'Uma Breve História do Tempo', 'Stephen Hawking', 'não-ficção', 1988, 5490, 10,
 $d$Do Big Bang aos buracos negros.$d$,
 $d$O universo teve um começo? Terá um fim? O que acontece dentro de um buraco negro? Stephen Hawking explica, sem equações, as grandes ideias da cosmologia: relatividade, mecânica quântica, a expansão do universo e a busca por uma teoria unificada. Um dos livros de ciência mais vendidos da história, escrito para qualquer leitor curioso.$d$),

('BK035', 'Clean Code', 'Robert C. Martin', 'tecnologia', 2008, 12990, 15,
 $d$Práticas para escrever código legível e sustentável.$d$,
 $d$Código ruim funciona, mas cobra juros a cada mudança. Robert C. Martin reúne princípios e práticas para escrever código limpo: nomes significativos, funções pequenas, comentários que não mentem, tratamento de erros e testes unitários. A segunda parte traz estudos de caso de refatoração passo a passo. Uma referência para quem quer escrever software que outras pessoas consigam entender e manter.$d$),

('BK036', 'O Programador Pragmático', 'Andrew Hunt e David Thomas', 'tecnologia', 1999, 11990, 5,
 $d$Hábitos e ferramentas de quem constrói software bem.$d$,
 $d$Mais filosofia de trabalho do que manual técnico, o livro reúne dicas práticas para quem leva o ofício a sério: não repetir conhecimento (DRY), usar "balas traçantes" para validar arquitetura, automatizar tudo, dominar o editor e o controle de versão e assumir responsabilidade pelo próprio código. Um clássico que continua ajudando programadores a pensar como engenheiros.$d$),

('BK037', 'Designing Data-Intensive Applications', 'Martin Kleppmann', 'tecnologia', 2017, 17990, 5,
 $d$Como sistemas distribuídos guardam e processam dados.$d$,
 $d$Bancos relacionais ou NoSQL? Replicação síncrona ou assíncrona? Como particionar, garantir consistência e processar fluxos de eventos? Martin Kleppmann explica os fundamentos por trás dos sistemas de dados modernos, com as vantagens e os custos de cada escolha. Considerado leitura obrigatória para engenheiros de backend e arquitetos que trabalham com sistemas distribuídos.$d$),

('BK038', 'Arquitetura Limpa', 'Robert C. Martin', 'tecnologia', 2017, 13490, 3,
 $d$Fronteiras, dependências e desenho de sistemas.$d$,
 $d$Robert C. Martin parte dos paradigmas de programação e dos princípios SOLID para mostrar como organizar sistemas que resistem ao tempo: regras de negócio no centro, frameworks e bancos de dados como detalhes, e dependências sempre apontando para dentro. Com exemplos e histórias de projetos reais, o livro ensina a desenhar fronteiras que mantêm o software fácil de testar, implantar e evoluir.$d$),

('BK039', 'Site Reliability Engineering', 'Betsy Beyer e outros', 'tecnologia', 2016, 15990, 10,
 $d$Como o Google opera sistemas em produção.$d$,
 $d$Escrito por engenheiros do Google, o livro apresenta a disciplina de SRE: tratar operação como um problema de software. Explica objetivos de nível de serviço (SLOs), orçamento de erros, eliminação de trabalho repetitivo, monitoramento, resposta a incidentes e postmortems sem culpados. Referência para quem precisa manter serviços confiáveis em escala.$d$),

('BK040', 'A Arte da Guerra', 'Sun Tzu', 'não-ficção', NULL, 1990, 25,
 $d$Tratado clássico sobre estratégia.$d$,
 $d$Escrito na China antiga e atribuído ao general Sun Tzu, o tratado reúne em treze capítulos curtos princípios sobre planejamento, conhecimento do terreno, uso da surpresa e a arte de vencer sem precisar lutar. "Conheça o inimigo e conheça a si mesmo." Lido há séculos por militares, hoje também aparece em cursos de negócios, esportes e negociação.$d$);

-- O estoque inicial também entra no livro-razão: assim a invariante
-- `stock = Σ delta` vale desde o primeiro instante.
INSERT INTO stock_movements (product_id, delta, reason, ref, actor)
SELECT product_id, stock, 'seed', '0002_seed_catalog', 'migration' FROM products;

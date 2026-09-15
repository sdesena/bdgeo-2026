-- Identificação de duplicidades no código do imóvel
-- Verifica se o mesmo código de imóvel aparece mais de uma vez na base.

SELECT 
    cod_imovel, 
    COUNT(*) AS qtd_duplicadas
FROM raw.car_area_imovel_sp
GROUP BY cod_imovel
HAVING COUNT(*) > 1;


-- Validação topológica e presenças de nulos
-- Avalia a qualidade básica dos registros, identificando geometrias ausentes,
-- geometrias inválidas e valores de área nulos ou iguais a zero.

SELECT 
    COUNT(*) AS total_registros,
    COUNT(*) FILTER (WHERE geom IS NULL) AS geom_nulas,
    COUNT(*) FILTER (WHERE geom IS NOT NULL AND NOT ST_IsValid(geom)) AS geom_invalidas,
    COUNT(*) FILTER (WHERE area IS NULL OR area = 0) AS area_declarada_nula
FROM raw.car_area_imovel_sp;


-- Divergência entre Área Declarada e Área Calculada no GIS (diferença > 0.5 ha)
-- Compara a área informada no cadastro com a área calculada a partir da geometria.
-- São retornados apenas os imóveis cuja diferença seja superior a 0,5 hectare.

SELECT 
    cod_imovel,
    area AS area_declarada_ha,
    ROUND((ST_Area(geom::geography) / 10000.0)::numeric, 2) AS area_calculada_ha,
    ROUND(ABS(area - (ST_Area(geom::geography) / 10000.0))::numeric, 2) AS diferenca_ha
FROM raw.car_area_imovel_sp
WHERE geom IS NOT NULL
  AND ABS(area - (ST_Area(geom::geography) / 10000.0)) > 0.5
ORDER BY diferenca_ha DESC;


-- Consulta para Diagnosticar a Unidade de Medida por Registro
-- Compara a área declarada com a área calculada em m² e em hectares.
-- A razão entre os valores é usada para inferir a unidade de medida original.

SELECT 
    cod_imovel,
    area AS area_original,
    ROUND((ST_Area(geom::geography) / 10000.0)::numeric, 2) AS area_calculada_ha,
    CASE 
        -- Se a área original for próxima da área calculada em m² (razão próxima de 1)
        WHEN ABS(area / NULLIF(ST_Area(geom::geography), 0) - 1) < 0.2 THEN 'Metros Quadrados (m²)'
        
        -- Se a área original for próxima da área calculada em hectares (razão próxima de 1)
        WHEN ABS(area / NULLIF(ST_Area(geom::geography) / 10000.0, 0) - 1) < 0.2 THEN 'Hectares (ha)'
        
        -- Casos em que nenhuma das duas comparações apresenta correspondência suficiente.
        ELSE 'Indefinido / Divergência Grave'
    END AS unidade_detectada
FROM raw.car_area_imovel_sp
WHERE geom IS NOT NULL;


-- Visão Geral do Impacto da Mistura na Base Toda
-- Resume o diagnóstico anterior para toda a base, mostrando a quantidade
-- e o percentual de imóveis classificados em cada unidade de medida.

WITH diagnostico_unidade AS (
    SELECT 
        CASE 
            WHEN ABS(area / NULLIF(ST_Area(geom::geography), 0) - 1) < 0.2 THEN 'm2'
            WHEN ABS(area / NULLIF(ST_Area(geom::geography) / 10000.0, 0) - 1) < 0.2 THEN 'ha'
            ELSE 'indefinido'
        END AS unidade
    FROM raw.car_area_imovel_sp
    WHERE geom IS NOT NULL
)
SELECT 
    unidade,
    COUNT(*) AS total_imoveis,
    ROUND((COUNT(*) * 100.0 / SUM(COUNT(*)) OVER())::numeric, 2) AS pct_base
FROM diagnostico_unidade
GROUP BY unidade;


-- Distribuição por Status do Imóvel
-- Apresenta a quantidade de imóveis e suas respectivas áreas calculadas,
-- permitindo observar a distribuição espacial da base segundo o status cadastral.

SELECT 
    status_imovel,
    COUNT(*) AS qtd_imoveis,
    ROUND(SUM(ST_Area(geom::geography) / 10000.0)::numeric, 2) AS area_gis_total_ha,
    ROUND(AVG(ST_Area(geom::geography) / 10000.0)::numeric, 2) AS area_gis_media_ha
FROM raw.car_area_imovel_sp
WHERE geom IS NOT NULL
GROUP BY status_imovel
ORDER BY qtd_imoveis DESC;


-- Cruzamento entre Tipo de Imóvel e Condição
-- Agrupa as diferentes descrições de condição em categorias resumidas
-- para facilitar a interpretação e comparação dos resultados.

SELECT
    tipo_imovel,
    CASE
        WHEN condicao ILIKE 'Cancelado%' THEN 'Cancelado'
        WHEN condicao ILIKE 'Analisado, em conformidade%' THEN 'Conforme'
        WHEN condicao ILIKE 'Analisado, aguardando%'
          OR condicao ILIKE 'Analisado, em regularização%' THEN 'Em regularização/pendência'
        WHEN condicao ILIKE 'Aguardando análise%'
          OR condicao = 'Em análise' THEN 'Aguardando análise'
        ELSE 'Outro'
    END AS condicao_resumida,
    COUNT(*) AS qtd_imoveis
FROM raw.car_area_imovel_sp
WHERE geom IS NOT NULL
GROUP BY tipo_imovel, condicao_resumida
ORDER BY tipo_imovel, qtd_imoveis DESC;


-- Perfil por Faixa de Módulos Fiscais (Porte)
-- Classifica os imóveis segundo o número de módulos fiscais,
-- permitindo analisar a distribuição da base por porte da propriedade.

SELECT 
    CASE 
        WHEN m_fiscal <= 4 THEN '1. Pequena Propriedade (<= 4 MF)'
        WHEN m_fiscal > 4 AND m_fiscal <= 15 THEN '2. Média Propriedade (4 a 15 MF)'
        WHEN m_fiscal > 15 THEN '3. Grande Propriedade (> 15 MF)'
        ELSE '4. Não informado / Nulo'
    END AS faixa_porte,
    COUNT(*) AS qtd_imoveis,
    ROUND(SUM(ST_Area(geom::geography) / 10000.0)::numeric, 2) AS area_gis_total_ha
FROM raw.car_area_imovel_sp
WHERE geom IS NOT NULL
GROUP BY 1
ORDER BY 1;


-- Remove a tabela de preparação caso ela já exista,
-- permitindo executar novamente a etapa de preparação.

DROP TABLE IF EXISTS raw.car_area_imovel_sp_prep;


-- Cria uma tabela de staging para preparar os dados espaciais antes das análises.
-- As geometrias são transformadas para o SRID 5880 e corrigidas topologicamente.

CREATE TABLE staging.car_area_imovel_sp_prep AS
SELECT ogc_fid, id, cod_imovel, status_imovel, dat_criacao, area, condicao, uf, municipio, cod_municipio_ibge,
        m_fiscal, tipo_imovel,
       ST_MakeValid(ST_Transform(geom, 5880)) AS geom
FROM raw.car_area_imovel_sp
WHERE geom IS NOT NULL;


-- Cria um índice espacial para acelerar as consultas que utilizam
-- relacionamentos entre as geometrias da tabela de preparação.

CREATE INDEX ON staging.car_area_imovel_sp_prep USING GIST (geom);


-- Calcula as sobreposições entre pares de imóveis.
-- A preparação utiliza uma ordem por ogc_fid para evitar que o mesmo par
-- seja processado duas vezes e também evita comparar um imóvel consigo mesmo.

CREATE TABLE analytics.car_sobreposicoes AS
WITH pares AS (
    SELECT
        a.cod_imovel AS imovel_a, a.status_imovel AS status_a, a.tipo_imovel AS tipo_a, a.geom AS geom_a,
        b.cod_imovel AS imovel_b, b.status_imovel AS status_b, b.tipo_imovel AS tipo_b, b.geom AS geom_b,
        ST_Intersection(a.geom, b.geom) AS geom_conflito
    FROM raw.car_area_imovel_sp_prep a
    JOIN raw.car_area_imovel_sp_prep b
      ON a.ogc_fid < b.ogc_fid
      AND ST_Intersects(a.geom, b.geom)
      AND NOT ST_Touches(a.geom, b.geom)
),
calc AS (
    -- Calcula as áreas totais dos imóveis e a área efetivamente sobreposta.
    SELECT *,
        ST_Area(geom_a) / 10000.0 AS area_a_ha,
        ST_Area(geom_b) / 10000.0 AS area_b_ha,
        ST_Area(geom_conflito) / 10000.0 AS area_sobreposta_ha
    FROM pares
)
SELECT
    imovel_a, status_a, tipo_a, ROUND(area_a_ha::numeric, 4) AS area_total_a_ha,
    imovel_b, status_b, tipo_b, ROUND(area_b_ha::numeric, 4) AS area_total_b_ha,
    ROUND(area_sobreposta_ha::numeric, 4) AS area_sobreposta_ha,
    ROUND((area_sobreposta_ha / area_a_ha * 100)::numeric, 2) AS pct_comprometimento_a,
    ROUND((area_sobreposta_ha / area_b_ha * 100)::numeric, 2) AS pct_comprometimento_b,
    geom_conflito
FROM calc
-- Considera apenas sobreposições maiores que 0,1 hectare.
WHERE area_sobreposta_ha > 0.1;


-- Cria uma visão materializada com um resumo dos conflitos,
-- agrupando-os por combinação de status e tipo de imóvel.

CREATE MATERIALIZED VIEW analytics.car_resumo_status AS
SELECT
    LEAST(status_a, status_b) AS status_1,
    GREATEST(status_a, status_b) AS status_2,
    tipo_a, tipo_b,
    COUNT(*) AS qtd_conflitos,
    ROUND(SUM(area_sobreposta_ha), 2) AS total_hectares_em_disputa
FROM analytics.car_sobreposicoes
GROUP BY 1, 2, 3, 4
ORDER BY total_hectares_em_disputa DESC;


-- Classifica os conflitos entre imóveis ativos segundo a proporção
-- da área comprometida, destacando os casos de maior severidade.

CREATE MATERIALIZED VIEW analytics.car_conflitos_criticos AS
SELECT
    imovel_a, status_a, pct_comprometimento_a,
    imovel_b, status_b, pct_comprometimento_b,
    area_sobreposta_ha, tipo_a, tipo_b,
    CASE
        WHEN GREATEST(pct_comprometimento_a, pct_comprometimento_b) >= 90 THEN 'crítico'
        WHEN GREATEST(pct_comprometimento_a, pct_comprometimento_b) >= 70 THEN 'severo'
        ELSE 'moderado'
    END AS severidade
FROM analytics.car_sobreposicoes
WHERE GREATEST(pct_comprometimento_a, pct_comprometimento_b) > 50
  AND status_a = 'AT' AND status_b = 'AT'
ORDER BY GREATEST(pct_comprometimento_a, pct_comprometimento_b) DESC;


-- Identifica possíveis conflitos fundiários a partir de combinações
-- específicas de tipos de imóveis que estão simultaneamente ativos.

CREATE MATERIALIZED VIEW analytics.car_conflitos_fundiarios AS
SELECT
    imovel_a, tipo_a, status_a, pct_comprometimento_a,
    imovel_b, tipo_b, status_b, pct_comprometimento_b,
    area_sobreposta_ha
FROM analytics.car_sobreposicoes
WHERE status_a = 'AT' AND status_b = 'AT'
  AND (
       (tipo_a = 'IRU' AND tipo_b IN ('AST', 'PCT'))
    OR (tipo_b = 'IRU' AND tipo_a IN ('AST', 'PCT'))
  )
ORDER BY area_sobreposta_ha DESC;


-- Verifica o SRID das diferentes fontes espaciais antes do cruzamento.
-- Essa conferência permite identificar diferenças nos sistemas de referência.

SELECT 'prodes_mata_atlantica' AS tabela, ST_SRID(geom) FROM raw.prodes_mata_atlantica LIMIT 1;

SELECT 'prodes_cerrado', ST_SRID(geom) FROM raw.prodes_cerrado LIMIT 1;

SELECT 'car_reserva_legal_sp', ST_SRID(geom) FROM raw.car_reserva_legal_sp LIMIT 1;

SELECT 'car_area_preservacao_permanente_sp', ST_SRID(geom) FROM raw.car_area_preservacao_permanente_sp LIMIT 1;


-- Tamanho em disco (te dá noção do que vai demorar)
-- Consulta o tamanho das tabelas de origem para dar uma noção do volume
-- de dados que será manipulado nas operações seguintes.

SELECT relname, pg_size_pretty(pg_total_relation_size(relid))
FROM pg_catalog.pg_statio_user_tables
WHERE schemaname = 'raw'
  AND relname IN ('prodes_mata_atlantica','prodes_cerrado',
                   'car_reserva_legal_sp','car_area_preservacao_permanente_sp');


-- confira antes se as colunas batem entre as duas (nome, tipo)
-- Verifica a estrutura das tabelas de origem antes de integrá-las na mesma
-- etapa de processamento.

SELECT column_name, data_type FROM information_schema.columns WHERE table_schema='raw' AND table_name='prodes_mata_atlantica';

SELECT column_name, data_type FROM information_schema.columns WHERE table_schema='raw' AND table_name='prodes_cerrado';


-- Verifica a quantidade de geometrias inválidas presentes no PRODES
-- antes de utilizar a camada nas operações de interseção.

SELECT COUNT(*) FILTER (WHERE NOT ST_IsValid(geom)) AS invalidas, COUNT(*) AS total
FROM raw.prodes_mata_atlantica;


-- Verifica a quantidade de registros correspondentes às camadas
-- anuais de desmatamento que serão utilizadas na análise.

SELECT COUNT(*) FROM raw.prodes_mata_atlantica WHERE id LIKE 'yearly_deforestation%';

SELECT COUNT(*) FROM raw.prodes_cerrado WHERE id LIKE 'yearly_deforestation%';


-- Verifica a versão do PostGIS disponível no banco,
-- útil para registrar o ambiente utilizado no processamento.

SELECT postgis_full_version();


-- 1. Cria a tabela de staging primeiro
-- Define estruturas padronizadas para receber os dados das diferentes
-- fontes antes da realização dos cruzamentos espaciais.

CREATE TABLE staging.prodes_sp_prep (
    id varchar,
    class_name varchar,
    main_class varchar,
    year int4,
    area_km float8,
    state varchar,
    bioma varchar,
    geom geometry(multipolygon, 5880)
);

CREATE TABLE staging.car_app_sp_prep (
    cod_tema varchar,
    nom_tema varchar,
    cod_imovel varchar,
    num_area float8,
    ind_status varchar,
    des_condic varchar,
    geom geometry(multipolygon, 5880)
);

CREATE TABLE staging.car_reserva_legal_sp_prep (
    cod_tema varchar,
    nom_tema varchar,
    cod_imovel varchar,
    num_area float8,
    ind_status varchar,
    des_condic varchar,
    geom geometry(multipolygon, 5880)
);


-- 2. Popula em lotes por ano, já filtrando a camada certa
-- Processa o PRODES ano a ano e mantém apenas os registros do estado de SP.
-- A geometria é transformada, corrigida e normalizada antes da inserção.

DO $$
DECLARE ano int;
BEGIN
    FOR ano IN
        SELECT DISTINCT year FROM raw.prodes_mata_atlantica
        WHERE id LIKE 'yearly_deforestation%' ORDER BY year
    LOOP
        RAISE NOTICE 'Mata Atlântica - processando ano %', ano;

        INSERT INTO staging.prodes_sp_prep
        SELECT id, class_name, main_class, year, area_km, state, 'mata_atlantica',
               ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_Transform(geom, 5880)), 3)) AS geom
        FROM raw.prodes_mata_atlantica
        WHERE id LIKE 'yearly_deforestation%' AND year = ano AND state = 'SP';
    END LOOP;

    FOR ano IN
        SELECT DISTINCT year FROM raw.prodes_cerrado
        WHERE id LIKE 'yearly_deforestation%' ORDER BY year
    LOOP
        RAISE NOTICE 'Cerrado - processando ano %', ano;

        INSERT INTO staging.prodes_sp_prep
        SELECT id, class_name, main_class, year, area_km, state, 'cerrado',
               ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_Transform(geom, 5880)), 3)) AS geom
        FROM raw.prodes_cerrado
        WHERE id LIKE 'yearly_deforestation%' AND year = ano AND state = 'SP';
    END LOOP;
END $$;


-- 3. Índice espacial só depois de popular (mais rápido que indexar linha por linha)
-- Cria o índice após a carga completa para melhorar o desempenho das consultas
-- espaciais realizadas posteriormente.

CREATE INDEX ON staging.prodes_sp_prep USING GIST (geom);


-------------------------------------------------------------------------
-------------------------------------------------------------------------


-- Processa a Reserva Legal em lotes para controlar o volume de dados
-- manipulado por cada operação de transformação geométrica.

DO $$
DECLARE
    lote_tamanho int := 50000;
    fid_min int; fid_max int;
    inicio int; fim int;
BEGIN
    SELECT MIN(ogc_fid), MAX(ogc_fid) INTO fid_min, fid_max FROM raw.car_reserva_legal_sp;
    inicio := fid_min;

    WHILE inicio <= fid_max LOOP
        fim := inicio + lote_tamanho - 1;

        RAISE NOTICE 'Reserva Legal - processando ogc_fid % a %', inicio, fim;

        INSERT INTO staging.car_reserva_legal_sp_prep
        SELECT cod_tema, nom_tema, cod_imovel, num_area, ind_status, des_condic,
               ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_Transform(geom, 5880)), 3)) AS geom
        FROM raw.car_reserva_legal_sp
        WHERE ogc_fid BETWEEN inicio AND fim;

        inicio := fim + 1;
    END LOOP;
END $$;


-------------------------------------------------------------------------
-------------------------------------------------------------------------


-- Processa a camada de APP em lotes, com tratamento de exceções.
-- Caso um lote apresente erro, seus registros são reprocessados individualmente
-- para identificar e isolar eventuais geometrias problemáticas.

DO $$
DECLARE
    lote_tamanho int := 50000;
    fid_min int; fid_max int;
    inicio int; fim int;
    r record;
BEGIN
    SELECT MIN(ogc_fid), MAX(ogc_fid) INTO fid_min, fid_max FROM raw.car_area_preservacao_permanente_sp;
    inicio := fid_min;

    WHILE inicio <= fid_max LOOP
        fim := inicio + lote_tamanho - 1;

        RAISE NOTICE 'APP - processando ogc_fid % a %', inicio, fim;

        BEGIN
            INSERT INTO staging.car_app_sp_prep
            SELECT cod_tema, nom_tema, cod_imovel, num_area, ind_status, des_condic,
                   ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_Transform(geom, 5880)), 3)) AS geom
            FROM raw.car_area_preservacao_permanente_sp
            WHERE ogc_fid BETWEEN inicio AND fim;

        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'Lote % a % falhou (%), reprocessando linha a linha', inicio, fim, SQLERRM;

            FOR r IN
                SELECT ogc_fid, cod_tema, nom_tema, cod_imovel, num_area, ind_status, des_condic, geom
                FROM raw.car_area_preservacao_permanente_sp
                WHERE ogc_fid BETWEEN inicio AND fim
            LOOP
                BEGIN
                    INSERT INTO staging.car_app_sp_prep
                    SELECT r.cod_tema, r.nom_tema, r.cod_imovel, r.num_area, r.ind_status, r.des_condic,
                           ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_Transform(r.geom, 5880)), 3));

                EXCEPTION WHEN OTHERS THEN
                    RAISE NOTICE 'Pulando ogc_fid % - %', r.ogc_fid, SQLERRM;
                END;
            END LOOP;
        END;

        inicio := fim + 1;
    END LOOP;
END $$;


-- Cruza as geometrias de APP e Reserva Legal com os polígonos do PRODES.
-- O objetivo é identificar ocorrências de desmatamento dentro dessas áreas
-- e calcular a área efetivamente afetada.

CREATE TABLE analytics.desmatamento_areas_protegidas AS
SELECT 'APP' AS tipo_area, app.cod_imovel, app.ind_status, p.year, p.bioma,
    ROUND((ST_Area(ST_Intersection(app.geom, p.geom)) / 10000.0)::numeric, 4) AS area_desmatada_ha
FROM staging.car_app_sp_prep app
JOIN staging.prodes_sp_prep p ON ST_Intersects(app.geom, p.geom)
WHERE ST_Area(ST_Intersection(app.geom, p.geom)) / 10000.0 > 0.01

UNION ALL

SELECT 'RL' AS tipo_area, rl.cod_imovel, rl.ind_status, p.year, p.bioma,
    ROUND((ST_Area(ST_Intersection(rl.geom, p.geom)) / 10000.0)::numeric, 4) AS area_desmatada_ha
FROM staging.car_reserva_legal_sp_prep rl
JOIN staging.prodes_sp_prep p ON ST_Intersects(rl.geom, p.geom)
WHERE ST_Area(ST_Intersection(rl.geom, p.geom)) / 10000.0 > 0.01;


-- Cria índices nas colunas mais utilizadas pelas consultas analíticas seguintes.

CREATE INDEX ON analytics.desmatamento_areas_protegidas (cod_imovel);

CREATE INDEX ON analytics.desmatamento_areas_protegidas (tipo_area, year);


-- Consolida o desmatamento por tipo de área protegida, bioma e ano,
-- permitindo analisar a quantidade de imóveis afetados e a área total.

CREATE MATERIALIZED VIEW analytics.desmatamento_por_ano AS
SELECT tipo_area, bioma, year,
    COUNT(DISTINCT cod_imovel) AS qtd_imoveis_afetados,
    ROUND(SUM(area_desmatada_ha), 2) AS area_desmatada_total_ha
FROM analytics.desmatamento_areas_protegidas
GROUP BY tipo_area, bioma, year
ORDER BY year;


-- Gera um ranking dos imóveis segundo a área total de desmatamento identificada,
-- registrando também o primeiro e o último ano em que houve ocorrência.

CREATE MATERIALIZED VIEW analytics.ranking_desmatamento_imovel AS
SELECT cod_imovel, tipo_area,
    COUNT(*) AS qtd_ocorrencias,
    ROUND(SUM(area_desmatada_ha), 2) AS area_desmatada_total_ha,
    MIN(year) AS primeiro_ano, MAX(year) AS ultimo_ano
FROM analytics.desmatamento_areas_protegidas
GROUP BY cod_imovel, tipo_area
ORDER BY area_desmatada_total_ha DESC;


-- Compara APP e Reserva Legal quanto à quantidade de imóveis afetados
-- e à área total de desmatamento identificada em cada tipo de área.

CREATE MATERIALIZED VIEW analytics.comparacao_app_rl AS
SELECT tipo_area,
    COUNT(DISTINCT cod_imovel) AS qtd_imoveis_afetados,
    ROUND(SUM(area_desmatada_ha), 2) AS area_desmatada_total_ha
FROM analytics.desmatamento_areas_protegidas
GROUP BY tipo_area;


-- Combina os indicadores de conflitos fundiários e desmatamento.
-- A consulta considera somente imóveis que apresentam simultaneamente
-- os dois tipos de ocorrência.

CREATE MATERIALIZED VIEW analytics.imoveis_risco_composto AS
WITH conflitos AS (
    SELECT imovel_a AS cod_imovel, area_sobreposta_ha
    FROM analytics.car_sobreposicoes
    WHERE status_a='AT' AND status_b='AT'

    UNION ALL

    SELECT imovel_b AS cod_imovel, area_sobreposta_ha
    FROM analytics.car_sobreposicoes
    WHERE status_a='AT' AND status_b='AT'
),
conflitos_agg AS (
    -- Consolida os conflitos por imóvel.
    SELECT cod_imovel, COUNT(*) AS qtd_conflitos, ROUND(SUM(area_sobreposta_ha), 2) AS area_conflito_ha
    FROM conflitos
    GROUP BY cod_imovel
),
desmatamento_agg AS (
    -- Consolida a área total de desmatamento identificada por imóvel.
    SELECT cod_imovel, ROUND(SUM(area_desmatada_ha), 2) AS area_desmatada_ha
    FROM analytics.desmatamento_areas_protegidas
    GROUP BY cod_imovel
)
SELECT c.cod_imovel, c.qtd_conflitos, c.area_conflito_ha, d.area_desmatada_ha
FROM conflitos_agg c
-- O JOIN garante que somente imóveis com ambos os tipos de ocorrência sejam mantidos.
JOIN desmatamento_agg d ON c.cod_imovel = d.cod_imovel
ORDER BY d.area_desmatada_ha DESC;

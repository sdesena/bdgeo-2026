# BDGeo 2026

## Requisitos
- Docker
- Docker Compose

## 1) Subir o ambiente
```bash
docker compose up -d --build
```

## 2) Criar tabelas e funções do banco

```bash
docker compose --profile tools run --rm etl bash -lc 'psql -f ./sql/00-bdgeo.sql'
docker compose --profile tools run --rm etl bash -lc 'psql -f ./sql/01-bdgeo.sql'
```

## 3) Executar ETLs
```bash
docker compose --profile tools run --rm etl bash ./scripts/etl_cadastro_ambiental_rural.sh
docker compose --profile tools run --rm etl bash ./scripts/etl_prodes_desmatamentos.sh
```

# 4) Criar os buckets depois de subir o RustFS
```bash
docker compose --profile setup run --rm rustfs-setup
```


## Resumo

### Fluxo do pipeline

```mermaid
flowchart TD
    subgraph RAW["Schema: raw (dados originais)"]
        A1[car_area_imovel_sp]
        A2[car_area_preservacao_permanente_sp]
        A3[car_reserva_legal_sp]
        A4[prodes_mata_atlantica]
        A5[prodes_cerrado]
    end

    subgraph STAGING["Schema: staging ST_MakeValid + ST_Transform para EPSG:5880"]
        B1[car_area_imovel_sp_prep]
        B2["staging.car_app_sp_prep"]
        B3["staging.car_reserva_legal_sp_prep"]
        B4["staging.prodes_sp_prep<br/>(filtro: só camada yearly_deforestation)"]
    end

    subgraph ANALYTICS["Schema: analytics (cruzamentos)"]
        C1["car_sobreposicoes<br/>self-join imóvel × imóvel"]
        C2["desmatamento_areas_protegidas<br/>APP/RL × PRODES"]
    end

    subgraph RESUMOS["Materialized views (para os gráficos)"]
        D1[car_resumo_status]
        D2[car_conflitos_criticos]
        D3["car_conflitos_fundiarios<br/>(IRU × AST/PCT)"]
        D4[mv_desmatamento_por_ano]
        D5[mv_ranking_desmatamento_imovel]
        D6[mv_comparacao_app_rl]
        D7["mv_imoveis_risco_composto<br/>(achado principal)"]
    end

    A1 --> B1
    A2 --> B2
    A3 --> B3
    A4 --> B4
    A5 --> B4

    B1 --> C1
    B2 --> C2
    B3 --> C2
    B4 --> C2

    C1 --> D7
    C1 --> D1
    C1 --> D2
    C1 --> D3
    C2 --> D4
    C2 --> D5
    C2 --> D6
    C2 --> D7
```

**Decisões técnicas do pipeline** (vale mencionar na seção de metodologia):
- Reprojeção de EPSG:4674 (geográfico) para EPSG:5880 (SIRGAS 2000 / Brazil Polyconic) — cálculos de área e interseção em coordenadas métricas, sem depender de zona UTM específica.
- `ST_MakeValid` aplicado a todas as camadas antes de qualquer cruzamento — CAR e PRODES têm parcela relevante de geometrias com self-intersections.
- Processamento em lotes com fallback linha-a-linha, pra lidar com geometrias corrompidas isoladas sem interromper o processamento de milhões de registros.

---

## Blocos de análise, cada um respondendo uma pergunta

### 1. Sobreposição entre imóveis do CAR
**Pergunta:** há cadastros que se sobrepõem entre si de forma incompatível com a realidade fundiária?

| Tabela | O que mostra |
|---|---|
| `car_resumo_status` | Gravidade cruzando status do cadastro (Ativo×Ativo é o que importa; Cancelado×Ativo costuma ser só histórico de correção) |
| `car_conflitos_criticos` | Pares com sobreposição >50% da área, classificados em moderado/severo/crítico |
| `car_conflitos_fundiarios` | **Achado mais forte deste bloco** — sobreposição entre `IRU` (imóvel privado) e `AST`/`PCT` (assentamento / comunidade tradicional). Tem significado jurídico direto, diferente de sobreposição genérica entre dois imóveis privados |

### 2. Desmatamento dentro de área legalmente protegida declarada
**Pergunta:** existe desmatamento (PRODES) dentro de área que o próprio proprietário declarou como protegida no CAR (APP ou Reserva Legal)?

| Tabela | O que mostra |
|---|---|
| `mv_desmatamento_por_ano` | Tendência temporal — aumentando ou diminuindo? |
| `mv_ranking_desmatamento_imovel` | Piores casos, por área desmatada acumulada |
| `mv_comparacao_app_rl` | Proporcionalmente, APP ou Reserva Legal sofre mais desmatamento? |

### 3. Risco composto (achado principal para fechar a apresentação)
**Pergunta:** existem imóveis que acumulam múltiplos indícios de irregularidade ao mesmo tempo?

| Tabela | O que mostra |
|---|---|
| `mv_imoveis_risco_composto` | Imóveis presentes tanto em conflito de sobreposição quanto em desmatamento de área protegida — lista priorizada de candidatos a auditoria |

---


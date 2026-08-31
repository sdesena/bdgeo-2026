FROM geopython/pygeoapi:latest

# Copia a configuração customizada (substitui a config padrão de exemplo)
COPY pygeoapi-config.yml /pygeoapi/local.config.yml

# Copia os arquivos .gpkg usados pelas coleções
COPY data/ /pygeoapi/data/

#!/bin/sh

# Interrompe a execução imediatamente se qualquer comando retornar erro
set -e

# Imprime mensagens informativas nos logs de deploy para monitoramento
echo "Iniciando pygeoapi..."
echo "PORT=${PORT}"

# Substitui a porta padrão (5000) pela porta dinâmica fornecida pelo Render ($PORT)
# O resultado é gravado em um novo arquivo de configuração no diretório temporário /tmp
sed "s/port: 5000/port: ${PORT}/" \
    /app/pygeoapi-config.yml \
    > /tmp/pygeoapi-config.yml

# Define as variáveis de ambiente necessárias para o pygeoapi encontrar os arquivos de configuração
export PYGEOAPI_CONFIG=/tmp/pygeoapi-config.yml
export PYGEOAPI_OPENAPI=/app/pygeoapi-openapi.yml

# Substitui o processo do shell pelo servidor de produção Gunicorn:
# --bind: conecta a API a todas as interfaces de rede na porta atribuída ($PORT)
# --workers 1 --threads 2: limita a carga em 1 processo para conter o uso de RAM (evitando estouro de memória)
# pygeoapi.flask_app:APP: carrega o objeto Flask da aplicação (APP em maiúsculas)
exec gunicorn --bind 0.0.0.0:${PORT} --workers 1 --threads 2 pygeoapi.flask_app:APP
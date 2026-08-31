from pygeoapi.process.base import BaseProcessor

# ==============================================================================
# METADADOS DO PROCESSO (OGC API - PROCESSES)
# Define o esquema de entrada, saída e comportamento do algoritmo exposto pela API
# ==============================================================================
PROCESS_METADATA = {
    "version": "1.0.0",                                          # Versão do algoritmo
    "id": "exemplo",                                             # Identificador único do processo na URL (/processes/exemplo)
    "title": "Processo de exemplo",                              # Título exibido na interface/documentação
    "description": "Processo de teste da OGC API - Processes",   # Descrição detalhada do processo
    "jobControlOptions": ["sync-execute"],                       # Define execução síncrona (retorna o resultado imediatamente)
    "outputTransmission": ["value"],                             # Retorna o resultado direto no corpo da resposta (inline)
    
    # Definição dos parâmetros esperados no corpo da requisição (Payload JSON)
    "inputs": {
        "mensagem": {
            "title": "Mensagem",
            "description": "Mensagem de entrada",
            "schema": {
                "type": "string"                                 # Espera uma string como dado de entrada
            }
        }
    },
    
    # Definição do formato da resposta gerada após o processamento
    "outputs": {
        "resultado": {
            "title": "Resultado",
            "schema": {
                "type": "string"                                 # Retorna uma string como dado de saída
            }
        }
    }
}

# ==============================================================================
# CLASSE DE EXECUÇÃO DO PROCESSO
# Herda da classe base do pygeoapi para integrar o algoritmo à infraestrutura da API
# ==============================================================================
class ExemploProcessor(BaseProcessor):

    def __init__(self, provider_def):
        """
        Inicializa o processador passando as configurações definidas no YAML 
        para a classe pai (BaseProcessor) e associando os metadados (PROCESS_METADATA).
        """
        super().__init__(provider_def, PROCESS_METADATA)

    def execute(self, data):
        """
        Método principal executado quando o endpoint recebe um POST.
        
        :param data: Dicionário contendo os parâmetros passados pelo cliente no corpo da requisição
        :return: Tupla ou dicionário contendo o resultado (seguindo o esquema definido em 'outputs')
        """
        # Extrai o valor da chave 'mensagem'. Caso o cliente não envie, assume 'Olá!' como padrão
        mensagem = data.get("mensagem", "Olá!")
        
        # Monta a estrutura de retorno correspondente ao bloco 'outputs' dos metadados
        return {
            "resultado": f"Processamento executado: {mensagem}"
        }

    def __repr__(self):
        """
        Representação em texto da classe, útil para registros de depuração (logs) do servidor.
        """
        return "<ExemploProcessor>"
#!/bin/bash

# Script de Deploy ECS - Projeto BIA (VERSÃO CORRIGIDA)
# Autor: Amazon Q
# Versão: 1.1.0
# 
# Este script automatiza o processo de build e deploy para ECS
# com versionamento baseado em commit hash para facilitar rollbacks
# 
# CORREÇÕES APLICADAS:
# - Melhor tratamento de erros na atualização do serviço
# - Validação mais robusta da task definition
# - Force new deployment para garantir atualização
# - Melhor logging e debugging

set -e  # Para o script em caso de erro

# Configurações padrão
DEFAULT_REGION="us-east-1"
DEFAULT_ECR_REPO="bia"
DEFAULT_CLUSTER="cluster-bia-alb"
DEFAULT_SERVICE="service-bia-alb"
DEFAULT_TASK_FAMILY="task-def-bia-alb"

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Função para exibir mensagens coloridas
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    if [ "$DEBUG" = "true" ]; then
        echo -e "${YELLOW}[DEBUG]${NC} $1"
    fi
}

# Função de ajuda
show_help() {
    cat << EOF
Script de Deploy ECS - Projeto BIA (VERSÃO CORRIGIDA)

USAGE:
    ./deploy-ecs-fixed.sh [COMMAND] [OPTIONS]

COMMANDS:
    deploy          Faz build da imagem e deploy para ECS
    rollback        Faz rollback para uma versão anterior
    list-versions   Lista as versões disponíveis no ECR
    status          Mostra status atual do serviço
    help            Mostra esta ajuda

OPTIONS:
    -r, --region REGION         Região AWS (default: $DEFAULT_REGION)
    -e, --ecr-repo REPO         Nome do repositório ECR (default: $DEFAULT_ECR_REPO)
    -c, --cluster CLUSTER       Nome do cluster ECS (default: $DEFAULT_CLUSTER)
    -s, --service SERVICE       Nome do serviço ECS (default: $DEFAULT_SERVICE)
    -f, --task-family FAMILY    Família da task definition (default: $DEFAULT_TASK_FAMILY)
    -t, --tag TAG               Tag específica para rollback
    --debug                     Ativa modo debug
    --force                     Força novo deployment mesmo sem mudanças
    -h, --help                  Mostra esta ajuda

EXAMPLES:
    # Deploy normal (usa commit hash atual)
    ./deploy-ecs-fixed.sh deploy

    # Deploy com debug ativado
    ./deploy-ecs-fixed.sh deploy --debug

    # Deploy forçado
    ./deploy-ecs-fixed.sh deploy --force

    # Verificar status do serviço
    ./deploy-ecs-fixed.sh status

    # Rollback para uma versão específica
    ./deploy-ecs-fixed.sh rollback -t abc1234

    # Listar versões disponíveis
    ./deploy-ecs-fixed.sh list-versions

CORREÇÕES APLICADAS:
    - Force new deployment para garantir atualização
    - Melhor validação da task definition
    - Tratamento robusto de erros
    - Comando status para debugging
    - Modo debug para troubleshooting

EOF
}

# Função para obter o commit hash atual
get_commit_hash() {
    if git rev-parse --git-dir > /dev/null 2>&1; then
        git rev-parse --short=7 HEAD
    else
        log_error "Este diretório não é um repositório Git"
        exit 1
    fi
}

# Função para fazer login no ECR
ecr_login() {
    local region=$1
    log_info "Fazendo login no ECR..."
    aws ecr get-login-password --region $region | docker login --username AWS --password-stdin $(aws sts get-caller-identity --query Account --output text).dkr.ecr.$region.amazonaws.com
}

# Função para verificar se o repositório ECR existe
check_ecr_repo() {
    local region=$1
    local repo_name=$2
    
    log_info "Verificando repositório ECR: $repo_name"
    if ! aws ecr describe-repositories --repository-names $repo_name --region $region > /dev/null 2>&1; then
        log_error "Repositório ECR '$repo_name' não encontrado na região '$region'"
        log_info "Crie o repositório com: aws ecr create-repository --repository-name $repo_name --region $region"
        exit 1
    fi
}

# Função para fazer build da imagem
build_image() {
    local tag=$1
    local ecr_uri=$2
    
    log_info "Fazendo build da imagem Docker..."
    log_info "Tag: $tag"
    
    # Build com múltiplas tags
    docker build -t bia-app:$tag -t bia-app:latest -t $ecr_uri:$tag -t $ecr_uri:latest .
    
    log_success "Build concluído com sucesso"
}

# Função para fazer push da imagem
push_image() {
    local tag=$1
    local ecr_uri=$2
    
    log_info "Fazendo push da imagem para ECR..."
    docker push $ecr_uri:$tag
    docker push $ecr_uri:latest
    
    log_success "Push concluído com sucesso"
}

# Função para verificar se o serviço existe
check_service_exists() {
    local region=$1
    local cluster=$2
    local service=$3
    
    log_debug "Verificando se o serviço existe: $service"
    
    local service_info=$(aws ecs describe-services \
        --region $region \
        --cluster $cluster \
        --services $service \
        --query 'services[0]' \
        --output json 2>/dev/null)
    
    if [ $? -ne 0 ] || [ "$(echo "$service_info" | jq -r '.serviceName')" = "null" ]; then
        log_error "Serviço '$service' não encontrado no cluster '$cluster'"
        log_info "Verifique se o serviço existe e se você tem permissões adequadas"
        exit 1
    fi
    
    log_debug "Serviço encontrado: $(echo "$service_info" | jq -r '.serviceName')"
}

# Função para obter status do serviço
get_service_status() {
    local region=$1
    local cluster=$2
    local service=$3
    
    log_info "Obtendo status do serviço..."
    
    local service_info=$(aws ecs describe-services \
        --region $region \
        --cluster $cluster \
        --services $service \
        --query 'services[0]' \
        --output json)
    
    if [ $? -ne 0 ]; then
        log_error "Falha ao obter informações do serviço"
        exit 1
    fi
    
    local current_task_def=$(echo "$service_info" | jq -r '.taskDefinition')
    local running_count=$(echo "$service_info" | jq -r '.runningCount')
    local desired_count=$(echo "$service_info" | jq -r '.desiredCount')
    local status=$(echo "$service_info" | jq -r '.status')
    
    echo "=== STATUS DO SERVIÇO ==="
    echo "Serviço: $service"
    echo "Cluster: $cluster"
    echo "Status: $status"
    echo "Task Definition Atual: $current_task_def"
    echo "Tasks Rodando: $running_count"
    echo "Tasks Desejadas: $desired_count"
    echo "========================="
}

# Função para criar nova task definition
create_task_definition() {
    local region=$1
    local task_family=$2
    local ecr_uri=$3
    local tag=$4
    
    log_info "Obtendo task definition atual: $task_family"
    
    # Obter a task definition atual
    local current_task_def=$(aws ecs describe-task-definition \
        --task-definition $task_family \
        --region $region \
        --query 'taskDefinition' \
        --output json 2>/dev/null)
    
    if [ $? -ne 0 ]; then
        log_error "Não foi possível obter a task definition atual: $task_family"
        log_info "Verifique se a task definition existe e se você tem permissões adequadas"
        exit 1
    fi
    
    log_debug "Task definition atual obtida com sucesso"
    
    # Salvar em arquivo temporário para melhor manipulação
    local temp_file=$(mktemp)
    echo "$current_task_def" > "$temp_file"
    
    log_debug "Task definition salva em: $temp_file"
    
    # Verificar se há containers na task definition
    local container_count=$(jq '.containerDefinitions | length' "$temp_file")
    if [ "$container_count" -eq 0 ]; then
        log_error "Nenhum container encontrado na task definition"
        rm -f "$temp_file"
        exit 1
    fi
    
    log_debug "Containers encontrados: $container_count"
    
    # Criar nova task definition com a nova imagem
    local new_image="$ecr_uri:$tag"
    log_info "Atualizando imagem para: $new_image"
    
    local new_task_def=$(jq --arg image "$new_image" '
        .containerDefinitions[0].image = $image |
        del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .placementConstraints, .compatibilities, .registeredAt, .registeredBy)
    ' "$temp_file")
    
    # Salvar nova task definition em arquivo temporário
    local new_temp_file=$(mktemp)
    echo "$new_task_def" > "$new_temp_file"
    
    log_debug "Nova task definition salva em: $new_temp_file"
    
    if [ "$DEBUG" = "true" ]; then
        log_debug "Conteúdo da nova task definition:"
        jq '.' "$new_temp_file"
    fi
    
    log_info "Registrando nova task definition..."
    
    # Registrar nova task definition e capturar o resultado completo
    local register_result=$(aws ecs register-task-definition \
        --region $region \
        --cli-input-json file://"$new_temp_file" \
        --output json 2>&1)
    
    local register_status=$?
    
    # Limpar arquivos temporários
    rm -f "$temp_file" "$new_temp_file"
    
    if [ $register_status -ne 0 ]; then
        log_error "Falha ao registrar nova task definition"
        log_error "Detalhes: $register_result"
        exit 1
    fi
    
    # Extrair a revision do resultado
    local new_revision=$(echo "$register_result" | jq -r '.taskDefinition.revision')
    
    if [ "$new_revision" = "null" ] || [ -z "$new_revision" ]; then
        log_error "Não foi possível obter a revision da nova task definition"
        log_debug "Resultado do registro: $register_result"
        exit 1
    fi
    
    log_success "Nova task definition criada: $task_family:$new_revision"
    log_debug "Revision: $new_revision"
    
    # Retornar apenas a revision
    echo "$new_revision"
}

# Função para atualizar o serviço ECS (VERSÃO CORRIGIDA)
update_service() {
    local region=$1
    local cluster=$2
    local service=$3
    local task_family=$4
    local revision=$5
    local force_deployment=${6:-false}
    
    # Verificar se a revision é válida
    if [ -z "$revision" ] || [ "$revision" = "null" ]; then
        log_error "Revision inválida: '$revision'"
        exit 1
    fi
    
    local task_definition="$task_family:$revision"
    log_info "Atualizando serviço ECS..."
    log_info "Task Definition: $task_definition"
    log_info "Force Deployment: $force_deployment"
    
    # Verificar se o serviço existe antes de tentar atualizar
    check_service_exists $region $cluster $service
    
    # Construir comando de atualização
    local update_cmd="aws ecs update-service --region $region --cluster $cluster --service $service --task-definition $task_definition"
    
    # Adicionar force new deployment se solicitado ou se for deploy normal
    if [ "$force_deployment" = "true" ] || [ "$FORCE_DEPLOYMENT" = "true" ]; then
        update_cmd="$update_cmd --force-new-deployment"
        log_info "Forçando novo deployment..."
    fi
    
    log_debug "Comando de atualização: $update_cmd"
    
    # Executar atualização
    local update_result=$(eval "$update_cmd" 2>&1)
    local update_status=$?
    
    if [ $update_status -ne 0 ]; then
        log_error "Falha ao atualizar o serviço ECS"
        log_error "Detalhes: $update_result"
        
        # Tentar novamente com force deployment se não foi usado
        if [ "$force_deployment" != "true" ] && [ "$FORCE_DEPLOYMENT" != "true" ]; then
            log_warning "Tentando novamente com force deployment..."
            update_cmd="$update_cmd --force-new-deployment"
            update_result=$(eval "$update_cmd" 2>&1)
            update_status=$?
            
            if [ $update_status -ne 0 ]; then
                log_error "Falha mesmo com force deployment"
                log_error "Detalhes: $update_result"
                exit 1
            fi
        else
            exit 1
        fi
    fi
    
    log_success "Serviço atualizado com sucesso"
    
    if [ "$DEBUG" = "true" ]; then
        log_debug "Resultado da atualização:"
        echo "$update_result" | jq '.'
    fi
    
    log_info "Aguardando estabilização do serviço..."
    log_info "Isso pode levar alguns minutos..."
    
    # Aguardar estabilização com timeout maior
    local wait_start=$(date +%s)
    aws ecs wait services-stable --region $region --cluster $cluster --services $service
    local wait_status=$?
    local wait_end=$(date +%s)
    local wait_duration=$((wait_end - wait_start))
    
    if [ $wait_status -ne 0 ]; then
        log_warning "Timeout aguardando estabilização do serviço (${wait_duration}s)"
        log_info "O deploy pode ter sido bem-sucedido, verificando status..."
        
        # Verificar status atual
        get_service_status $region $cluster $service
        
        log_info "Verifique o console AWS para mais detalhes"
    else
        log_success "Serviço estabilizado com sucesso! (${wait_duration}s)"
        
        # Mostrar status final
        get_service_status $region $cluster $service
    fi
}

# Função para listar versões disponíveis
list_versions() {
    local region=$1
    local repo_name=$2
    
    log_info "Listando versões disponíveis no ECR..."
    
    aws ecr describe-images \
        --repository-name $repo_name \
        --region $region \
        --query 'sort_by(imageDetails,&imagePushedAt)[*].[imageTags[0],imagePushedAt]' \
        --output table
}

# Função principal de deploy (VERSÃO CORRIGIDA)
deploy() {
    local region=$1
    local ecr_repo=$2
    local cluster=$3
    local service=$4
    local task_family=$5
    
    # Obter informações necessárias
    local commit_hash=$(get_commit_hash)
    local account_id=$(aws sts get-caller-identity --query Account --output text)
    local ecr_uri="$account_id.dkr.ecr.$region.amazonaws.com/$ecr_repo"
    
    log_info "=== INICIANDO DEPLOY ==="
    log_info "Commit Hash: $commit_hash"
    log_info "ECR URI: $ecr_uri"
    log_info "Cluster: $cluster"
    log_info "Service: $service"
    log_info "Task Family: $task_family"
    log_info "========================"
    
    # Verificar se o repositório ECR existe
    check_ecr_repo $region $ecr_repo
    
    # Verificar se o serviço existe
    check_service_exists $region $cluster $service
    
    # Login no ECR
    ecr_login $region
    
    # Build da imagem
    build_image $commit_hash $ecr_uri
    
    # Push da imagem
    push_image $commit_hash $ecr_uri
    
    # Criar nova task definition
    log_info "Criando nova task definition..."
    local new_revision=$(create_task_definition $region $task_family $ecr_uri $commit_hash)
    
    if [ -z "$new_revision" ] || [ "$new_revision" = "null" ]; then
        log_error "Falha ao obter revision da nova task definition"
        exit 1
    fi
    
    # Atualizar serviço com force deployment
    log_info "Atualizando serviço ECS..."
    update_service $region $cluster $service $task_family $new_revision true
    
    log_success "=== DEPLOY FINALIZADO ==="
    log_info "Versão deployada: $commit_hash"
    log_info "Task Definition: $task_family:$new_revision"
    log_info "=========================="
}

# Função de rollback
rollback() {
    local region=$1
    local ecr_repo=$2
    local cluster=$3
    local service=$4
    local task_family=$5
    local target_tag=$6
    
    if [ -z "$target_tag" ]; then
        log_error "Tag para rollback não especificada. Use -t ou --tag"
        exit 1
    fi
    
    local account_id=$(aws sts get-caller-identity --query Account --output text)
    local ecr_uri="$account_id.dkr.ecr.$region.amazonaws.com/$ecr_repo"
    
    log_info "=== INICIANDO ROLLBACK ==="
    log_info "Target Tag: $target_tag"
    log_info "=========================="
    
    # Verificar se a imagem existe
    if ! aws ecr describe-images --repository-name $ecr_repo --region $region --image-ids imageTag=$target_tag > /dev/null 2>&1; then
        log_error "Imagem com tag '$target_tag' não encontrada no ECR"
        exit 1
    fi
    
    # Verificar se o serviço existe
    check_service_exists $region $cluster $service
    
    # Criar nova task definition com a imagem de rollback
    local new_revision=$(create_task_definition $region $task_family $ecr_uri $target_tag)
    
    # Atualizar serviço com force deployment
    update_service $region $cluster $service $task_family $new_revision true
    
    log_success "=== ROLLBACK CONCLUÍDO ==="
    log_info "Versão atual: $target_tag"
    log_info "Task Definition: $task_family:$new_revision"
    log_info "=========================="
}

# Parsing dos argumentos
REGION=$DEFAULT_REGION
ECR_REPO=$DEFAULT_ECR_REPO
CLUSTER=$DEFAULT_CLUSTER
SERVICE=$DEFAULT_SERVICE
TASK_FAMILY=$DEFAULT_TASK_FAMILY
COMMAND=""
TARGET_TAG=""
DEBUG="false"
FORCE_DEPLOYMENT="false"

while [[ $# -gt 0 ]]; do
    case $1 in
        deploy|rollback|list-versions|status|help)
            COMMAND=$1
            shift
            ;;
        -r|--region)
            REGION="$2"
            shift 2
            ;;
        -e|--ecr-repo)
            ECR_REPO="$2"
            shift 2
            ;;
        -c|--cluster)
            CLUSTER="$2"
            shift 2
            ;;
        -s|--service)
            SERVICE="$2"
            shift 2
            ;;
        -f|--task-family)
            TASK_FAMILY="$2"
            shift 2
            ;;
        -t|--tag)
            TARGET_TAG="$2"
            shift 2
            ;;
        --debug)
            DEBUG="true"
            shift
            ;;
        --force)
            FORCE_DEPLOYMENT="true"
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            log_error "Opção desconhecida: $1"
            show_help
            exit 1
            ;;
    esac
done

# Verificar se um comando foi especificado
if [ -z "$COMMAND" ]; then
    log_error "Nenhum comando especificado"
    show_help
    exit 1
fi

# Verificar dependências
if ! command -v aws &> /dev/null; then
    log_error "AWS CLI não encontrado. Instale o AWS CLI primeiro."
    exit 1
fi

if ! command -v docker &> /dev/null; then
    log_error "Docker não encontrado. Instale o Docker primeiro."
    exit 1
fi

if ! command -v jq &> /dev/null; then
    log_error "jq não encontrado. Instale o jq primeiro."
    exit 1
fi

# Mostrar configurações se debug estiver ativo
if [ "$DEBUG" = "true" ]; then
    log_debug "=== CONFIGURAÇÕES ==="
    log_debug "Região: $REGION"
    log_debug "ECR Repo: $ECR_REPO"
    log_debug "Cluster: $CLUSTER"
    log_debug "Service: $SERVICE"
    log_debug "Task Family: $TASK_FAMILY"
    log_debug "Debug: $DEBUG"
    log_debug "Force Deployment: $FORCE_DEPLOYMENT"
    log_debug "===================="
fi

# Executar comando
case $COMMAND in
    deploy)
        deploy $REGION $ECR_REPO $CLUSTER $SERVICE $TASK_FAMILY
        ;;
    rollback)
        rollback $REGION $ECR_REPO $CLUSTER $SERVICE $TASK_FAMILY $TARGET_TAG
        ;;
    list-versions)
        list_versions $REGION $ECR_REPO
        ;;
    status)
        get_service_status $REGION $CLUSTER $SERVICE
        ;;
    help)
        show_help
        ;;
    *)
        log_error "Comando desconhecido: $COMMAND"
        show_help
        exit 1
        ;;
esac

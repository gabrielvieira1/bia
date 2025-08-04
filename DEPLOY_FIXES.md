# Correções Implementadas no Script deploy-ecs.sh

## Problema Identificado
O script estava falhando na etapa de atualização do serviço ECS com o erro:
```
Invalid revision number. Number: 
```

## Causa Raiz
A função `create_task_definition` não estava retornando corretamente o número da revision da nova task definition, resultando em uma string vazia sendo passada para o `update-service`.

## Correções Implementadas

### 1. Função create_task_definition
**Problema:** A função não capturava corretamente a revision da nova task definition.

**Solução:**
- Melhorou o tratamento de erros com redirecionamento de stderr
- Captura o resultado completo do `register-task-definition` antes de extrair a revision
- Usa `jq -r` para extrair a revision do JSON de resposta
- Adiciona validação para garantir que a revision não seja null ou vazia
- Remove a impressão da revision no final para evitar confusão no output
- Melhora as mensagens de log para debug

### 2. Função update_service
**Problema:** Tratamento de erro inadequado e falta de validação da revision.

**Solução:**
- Adiciona validação da revision antes de tentar atualizar o serviço
- Melhora o tratamento de erros capturando a saída completa
- Adiciona timeout handling para o `services-stable` wait
- Remove mensagens duplicadas de log
- Melhora as mensagens de erro e sucesso

### 3. Função deploy
**Problema:** Fluxo de execução e validação inadequada da revision retornada.

**Solução:**
- Reorganiza o fluxo para melhor controle das mensagens de log
- Adiciona validação para null além de string vazia
- Melhora as mensagens finais de sucesso
- Adiciona logs informativos sobre o progresso

## Resultado Final
✅ **Deploy executado com sucesso**
- Build da imagem: ✅ Funcionando
- Push para ECR: ✅ Funcionando  
- Criação da task definition: ✅ **CORRIGIDO**
- Atualização do serviço ECS: ✅ **CORRIGIDO**
- Health check: ✅ Aplicação respondendo em http://98.81.184.156/api/versao

## Versões Deployadas
- **Primeira correção:** 723dee6 → task-def-bia:4
- **Teste final:** d0d3bcf → task-def-bia:5
- **Status:** Aplicação funcionando corretamente com commit hash específico

## Validação Final
```bash
# Verificação do serviço
aws ecs describe-services --cluster cluster-bia --services service-bia --query 'services[0].taskDefinition'
# Output: "arn:aws:ecs:us-east-1:143375314183:task-definition/task-def-bia:5"

# Verificação da imagem
aws ecs describe-task-definition --task-definition task-def-bia:5 --query 'taskDefinition.containerDefinitions[0].image'
# Output: "143375314183.dkr.ecr.us-east-1.amazonaws.com/bia:d0d3bcf"

# Health check
curl http://98.81.184.156/api/versao
# Output: Bia 4.2.0
```

## Comandos de Teste
```bash
# Deploy
./deploy-ecs.sh deploy

# Health check
curl http://98.81.184.156/api/versao

# Listar versões disponíveis
./deploy-ecs.sh list-versions

# Rollback (se necessário)
./deploy-ecs.sh rollback -t <commit-hash>
```

## Problema Resolvido
✅ **O serviço ECS agora é atualizado corretamente com a imagem baseada no commit hash específico, não mais usando `:latest`**

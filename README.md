# ArgoCD para entrega de software

Laboratório ativo-ativo com dois clusters Kubernetes no Kind. O gateway distribui requisições HTTP entre as duas regiões. A cada entrega, o Argo CD atualiza `east` e depois `west`. O hook `PreSync` retira a região do gateway e o `PostSync` recoloca a região após o Kubernetes indicar que o Deployment está saudável e o gateway conseguir acessar o serviço.

## Subir o laboratório

Você precisa de Docker com o daemon ativo, Kind, kubectl, Git e curl. O bootstrap usa Kubernetes v1.35.0 e Argo CD v3.6.1 por padrão. A primeira execução baixa imagens para o Docker e para os dois clusters.

```bash
git clone --branch 12-nov-2026-workshop https://github.com/bernardolsp/active-active-argo.git
cd active-active-argo
./setup.sh
```

O script cria `active-active-argo-east` e `active-active-argo-west`, instala o Argo CD nos dois e deixa a versão inicial da aplicação saudável nos dois clusters. O Argo de `east` gerencia as duas Applications e aguarda um refresh manual para buscar novas revisões do Git. O Argo de `west` fica disponível como instalação independente. Os hooks usam o gateway local e dispensam credenciais do Cloudflare.

O gateway roda em um container Docker fora dos clusters e distribui o tráfego pelos NodePorts `30080` de `east` e `west`. Os hooks do Kind chamam a API do gateway para tirar e recolocar cada região na rotação. O Docker escolhe uma porta livre em `127.0.0.1` para o gateway e o Kind escolhe as portas das APIs Kubernetes. Para rodar dois laboratórios ao mesmo tempo, use outro `LAB_NAME` e repita a variável em todos os comandos desse laboratório.

```bash
./setup.sh status
./setup.sh url
curl -si "$(./setup.sh url)/"
```

Abra o Argo CD em outro terminal com `./setup.sh ui east` ou `./setup.sh ui west`. O comando imprime o endereço local e escolhe uma porta livre. Use HTTPS e o usuário `admin`. A senha inicial sai em `./setup.sh password east` ou `./setup.sh password west`. Use o kubeconfig isolado em `.lab/<LAB_NAME>/kubeconfig` para consultar as Applications com kubectl.

```bash
kubectl --kubeconfig .lab/active-active-argo/kubeconfig \
  --context kind-active-active-argo-east -n argocd get applications
```

## Demonstrar uma entrega

1. Abra um terminal para acompanhar o tráfego. O cabeçalho `X-Lab-Region` indica o backend que atendeu cada requisição.

   ```bash
   url=$(./setup.sh url)
   while true; do
     curl -fsSI --max-time 5 "$url/" | awk 'tolower($1) == "x-lab-region:" { print $2 }'
     sleep 1
   done
   ```

2. Em outro terminal, altere `image.tag` de `v1.9.0` para `v1.11.0` em `app-default/values.yaml` e rode `./setup.sh publish`. O comando publica o chart no Git local, incluindo mudanças ainda sem commit. A versão que atende o tráfego continua a mesma até o refresh.
3. No Argo CD de `east`, abra `app-east` e escolha **Refresh → Hard Refresh**. O ApplicationSet atualiza a revisão de `app-west` e inicia o RollingSync. Aguarde o Argo CD iniciar a primeira onda em `east`, seguida de `west`.
4. Acompanhe `./setup.sh status` e consulte os eventos com `curl -fsS "$(./setup.sh url)/_lab/events"`. Durante a entrega, o tráfego fica na outra região. Depois das duas ondas, volta a alternar entre `east` e `west`. O atraso do `PreSync` é de cinco segundos por padrão. Para observar a troca por mais tempo, suba o laboratório com `DRAIN_SECONDS=15 ./setup.sh`.

O gateway registra cada mudança de tráfego com o SHA da entrega. Se o Argo CD repetir um sync da mesma revisão após o `PostSync`, os hooks preservam a região na rotação.

Se um deploy falhar após o `PreSync`, o gateway mantém aquela região fora da rotação. Publique a correção e acompanhe o próximo sync. Para consultar um hook que falhou, use `kubectl -n active-active-argo get jobs` e `kubectl -n active-active-argo logs job/<nome>` no contexto da região correspondente.

### Usar um repositório remoto

Para usar a branch publicada deste laboratório como fonte do Argo CD:

```bash
REPO_URL=https://github.com/bernardolsp/active-active-argo.git \
  GIT_REF=12-nov-2026-workshop ./setup.sh
```

Para demonstrar entregas a partir de um fork público, envie o código ao fork e use a branch que contém o chart.

```bash
REPO_URL=https://github.com/SEU-USUARIO/active-active-argo.git GIT_REF=minha-branch ./setup.sh
```

Nesse modo, faça commit e push para publicar a alteração. Dispare a entrega com **Hard Refresh** em `app-east`, como na demonstração local. Use os mesmos `REPO_URL` e `GIT_REF` se repetir o bootstrap. Sem essas variáveis, o script usa o Git local.

## Limpar

```bash
./setup.sh down
```

Isso remove os clusters do laboratório, o gateway e as credenciais locais geradas. O fluxo do Kind usa `lab/applicationset.yaml`.

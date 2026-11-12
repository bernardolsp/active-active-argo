# ArgoCD para entrega de software

Laboratório ativo-ativo com dois clusters Kubernetes no Kind. O gateway distribui requisições HTTP entre as duas regiões. A cada entrega, o Argo CD atualiza `east` e depois `west`. O hook `PreSync` retira a região do gateway e o `PostSync` recoloca a região após o Kubernetes indicar que o Deployment está saudável e o gateway conseguir acessar o serviço.

## Subir o laboratório

Você precisa de Docker com o daemon ativo, Kind, kubectl, Git e curl. O bootstrap usa Kubernetes v1.35.0 e Argo CD v3.6.1 por padrão. A primeira execução baixa imagens para o Docker e para os dois clusters.

```bash
git clone --branch 12-nov-2026-workshop https://github.com/bernardolsp/active-active-argo.git
cd active-active-argo
./setup.sh
```

O script cria `active-active-argo-east` e `active-active-argo-west` e instala um Argo CD central em `east`. Ele registra `west` como destino, implanta a versão inicial da branch `12-nov-2026-workshop` nos dois clusters e aguarda um refresh manual para buscar novas revisões no GitHub.

O gateway roda em um container Docker fora dos clusters e distribui o tráfego pelos NodePorts `30080` de `east` e `west`. Os hooks do Kind chamam a API do gateway para tirar e recolocar cada região na rotação. O Docker escolhe uma porta livre em `127.0.0.1` para o gateway e o Kind escolhe as portas das APIs Kubernetes. Para rodar dois laboratórios ao mesmo tempo, use outro `LAB_NAME` e repita a variável em todos os comandos desse laboratório.

```bash
./setup.sh status
./setup.sh url
curl -si "$(./setup.sh url)/"
```

Abra o Argo CD em outro terminal com `./setup.sh ui`. O comando imprime o endereço local e escolhe uma porta livre. Use HTTPS e o usuário `admin`. A senha inicial sai em `./setup.sh password`.

O Kind registra os dois contextos no kubeconfig em uso, seguindo `KUBECONFIG` ou `~/.kube/config`. O setup seleciona `kind-active-active-argo-east`. Use `kubectx` para listar ou alternar os contextos e consulte as Applications no Argo central.

```bash
kubectl --context kind-active-active-argo-east -n argocd get applications
```

## Demonstrar uma entrega

1. Abra um terminal para acompanhar o tráfego. O script mostra a hora, o status HTTP e a região que respondeu a cada requisição. Use Ctrl+C para parar.

   ```bash
   ./curl.sh
   ```

2. Em outro terminal, altere `image.tag` de `v1.9.0` para `v1.11.0` em `app-default/values.yaml`, faça commit e envie a alteração para a branch que o Argo CD acompanha. A versão que atende o tráfego continua a mesma até o refresh.

   ```bash
   git add app-default/values.yaml
   git commit -m "Atualiza a imagem da aplicação"
   git push
   ```

3. No Argo CD de `east`, abra `app-east` e escolha **Refresh → Hard Refresh**. O ApplicationSet atualiza a revisão de `app-west` e inicia o RollingSync. A primeira onda, em `east`, pode levar cerca de um minuto para começar. Depois dela, o Argo CD atualiza `west`.
4. Acompanhe `./setup.sh status` e consulte os eventos com `curl -fsS "$(./setup.sh url)/_lab/events"`. Durante a entrega, o tráfego fica na outra região. Depois das duas ondas, volta a alternar entre `east` e `west`. O atraso do `PreSync` é de cinco segundos por padrão. Para observar a troca por mais tempo, suba o laboratório com `DRAIN_SECONDS=15 ./setup.sh`.

O gateway registra cada mudança de tráfego com o SHA da entrega. Se o Argo CD repetir um sync da mesma revisão após o `PostSync`, os hooks preservam a região na rotação.

Se um deploy falhar após o `PreSync`, o gateway mantém aquela região fora da rotação. Publique a correção e acompanhe o próximo sync. Para consultar um hook que falhou, use `kubectl -n active-active-argo get jobs` e `kubectl -n active-active-argo logs job/<nome>` no contexto da região correspondente.

### Usar um fork

Se você for publicar a alteração em um fork público, configure a URL e a branch que contém o chart ao subir o laboratório.

```bash
REPO_URL=https://github.com/SEU-USUARIO/active-active-argo.git GIT_REF=minha-branch ./setup.sh
```

Use os mesmos `REPO_URL` e `GIT_REF` se repetir o setup.

## Limpar

```bash
./setup.sh down
```

Isso remove os clusters do laboratório, seus contextos do kubeconfig em uso, o gateway e as credenciais locais geradas. O fluxo do Kind usa `lab/applicationset.yaml`.

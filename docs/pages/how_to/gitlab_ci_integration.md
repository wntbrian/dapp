---
title: GitLab CI integration
sidebar: how_to
permalink: gitlab_ci_integration.html
---

## Objectives

Setup CI process using GitLab and dapp.

## Before you begin

* You need to have a Kubernetes cluster, and the kubectl command-line tool must be configured to communicate with your cluster.
* Server with GitLab
* Docker registry (GitLab embedded or somthere else)
* Host for build node (optional)
* You have an application successfully builded with dapp
* У вас есть приложение, которое успешно собирается и деплоится средствами dapp

## Infrastructure

- Kubernetes cluster
- GitLab with docker registry enabled
- Build node
- Deploy node

We don't recommend to run dapp in docker as it can give an unexpected result. Also, dapp use `~/.dapp/` folder, and dapp assumes this folder is preserved for all pipelines. That is why we don't recommend you to use for build e.g. cloud environments which don't preserve gitlab-runner files between runs for any pipelines.

Build, deploy and cleanup is a steps you need to setup. For all steps you need to use gitlab-runner, which will run `dapp`.

We recommend you to use in production separate hosts for build (build node) and for deploy (deploy node). The reasons are:
* for deploy you need an access to cluster through kubectl, and simply you can use master node
* building needs more resources than for deploying, and master node typically has no such resources
* build procces can affect on the master node, and can affect on the whole cluster

You need to setup gitlab runners with only two tags - build and deploy respectively for buyild stage and deploy stage. Cleanup stage will use both runners and don't need separate runner or node.

### Base setup

On build and deploy nodes you need to install and setup gitlab-runners. Follow these steps on both nodes:

1. Create GitLab project and push code into it.
2. Get registration token for runners. In your GitLab project open `Settings` -> `CI/CD`, expand `Runners` and find toke in section `Setup a specific Runner manually`
1. [Install gitlab-runners](https://docs.gitlab.com/runner/install/linux-manually.html):
    - `deploy runner` - on the master kubernetes node
    - `build runner` - on the separate node or on the master kubernetes node (not recommend for production)
1. Register gitlab-runner.

    [Use these steps](https://docs.gitlab.com/runner/register/index.html) to register runners, but:
    -  enter following tags associated with runners (if you have only one runner - enter both tags comma separated):
        - `build` - for build runner
        - `deploy` - for deploy runner
    - enter executor for both runners - `shell`;
1. Install docker if it is absent.

    On master kubernetes node docker already installed, and you need to [install](https://kubernetes.io/docs/setup/independent/install-kubeadm/#installing-docker) it only on your build node.
1. Add `gitlab-runner` user into `docker` group.
    ```
usermod -Ga docker gitlab-runner
```
1. Install dapp for `gitlab-runner` user.

    You need to [install latest dapp](https://flant.github.io/dapp/installation.html) for `gitlab-runner` user on both nodes.

### Setup deploy runner

Deploy runner need [helm](https://helm.sh/) and an access to kubernetes cluster through kubectl. Easy way is to use master kubernetes node for deploy.

Make following steps on the master node:
1. Install and init Helm.
    ```bash
curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get > get_helm.sh &&
chmod 700 get_helm.sh &&
./get_helm.sh &&
kubectl create serviceaccount tiller --namespace kube-system &&
kubectl create clusterrolebinding tiller --clusterrole=cluster-admin --serviceaccount=kube-system:tiller &&
helm init --service-account tiller
```
2. Install helm plugin `template` under `gitlab-runner` user
    ```
sudo su - gitlab-runner -c 'mkdir -p .helm/plugins &&
helm plugin install https://github.com/technosophos/helm-template'
```
3. Copy kubectl config to `gitlab-runner` user
    ```
mkdir -p /home/gitlab-runner/.kube &&
sudo cp -i /etc/kubernetes/admin.conf /home/gitlab-runner/.kube/config &&
sudo chown -R gitlab-runner:gitlab-runner /home/gitlab-runner/.kube
```

## Pipelines

When you have working build and deploy runners, you ready to setup GitLab pipeline.

Create `.gitlab-ci.yml` file in the project's root directory and add the following lines:

```yaml
variables:
  CI_NAMESPACE: ${CI_PROJECT_NAME}-${CI_ENVIRONMENT_SLUG}

stages:
  - build
  - deploy
  - cleanup_registry
  - cleanup_builder
```


### Setup build stage

```yaml
Build:
  stage: build
  script:
    ## used for debugging
    - dapp --version; pwd; set -x
    ## Always use "bp" option instead separate "build" and "push"
    ## In case of GitLab CI it is important to use --tag-ci option, or cleanup will not work.
    - dapp dimg bp ${CI_REGISTRY_IMAGE} --tag-ci
  tags:
    ## You specify there the tag of the runner to use. We need to use there build runner
    - build
    ## Cleanup will use schedules, and it is not necessary to rebuild images on running cleanup jobs.
    ## Therefore we need to specify
    ##
  except:
    - schedules
```

### Setup deploy stage


build:
  stage: build
  script:
    # Полезная информация, которая поможет для дебага билда, если будут проблемы (дабы найти, где был билд и узнать, что лежало в используемых переменных)
    - dapp --version; pwd; set -x
    # Собираем образ и пушим в регистри. Обратите внимание на ключ --tag-ci
    - dapp dimg bp ${CI_REGISTRY_IMAGE} --tag-ci
  tags:
    - build
  except:
    - schedules

deploy:
  stage: deploy
  script:
    # Создаём namespace под приложение, если такого ещё нет.
    - kubectl get ns "${CI_PROJECT_PATH_SLUG}-${CI_ENVIRONMENT_SLUG}" || kubectl create ns "${CI_PROJECT_PATH_SLUG}-${CI_ENVIRONMENT_SLUG}"
    # Достаём секретный ключ registrysecret для доступа куба в registry. Этот ключ нужно установить в Кубы, иначе деплой работать не будет.
    - kubectl get secret registrysecret -n kube-system -o json |
                      jq ".metadata.namespace = \"${CI_PROJECT_PATH_SLUG}-${CI_ENVIRONMENT_SLUG}\"|
                      del(.metadata.annotations,.metadata.creationTimestamp,.metadata.resourceVersion,.metadata.selfLink,.metadata.uid)" |
                      kubectl apply -f -
    # Деплой, обратите внимание на ключ --tag-ci
    - dapp kube deploy
      --tag-ci
      --namespace ${CI_PROJECT_PATH_SLUG}-${CI_ENVIRONMENT_SLUG}
      --set "global.env=${CI_ENVIRONMENT_SLUG}"
      --set "global.ci_url=$(echo ${CI_ENVIRONMENT_URL} | cut -d / -f 3)"
      $CI_REGISTRY_IMAGE
  environment:
    # Названия, исходя из которых будет формироваться namespace приложения в Кубах и домен.
    name: stage
    url: https://${CI_COMMIT_REF_NAME}.${CI_PROJECT_PATH_SLUG}.example.com
  dependencies:
    - build
  tags:
    - deploy
  except:
    - schedules

Cleanup registry:
  stage: cleanup_registry
  script:
    - dapp --version; pwd; set -x
    - dapp dimg cleanup repo ${CI_REGISTRY_IMAGE}
  only:
    - schedules
  tags:
    - deploy

Cleanup builder:
  stage: cleanup_builder
  script:
    - dapp --version; pwd; set -x
    - dapp dimg stages cleanup local
        --improper-cache-version
        --improper-git-commit
        --improper-repo-cache
        ${CI_REGISTRY_IMAGE}
  only:
    - schedules
  tags:
    - build
```

### параметры, получаемые от раннера

Кроме параметров, передаваемых в dapp в явном виде (как прописано выше, в `gitlab-ci.yaml`), есть переменные, которые берутся из окружения, но в явном виде не передаются.

для аутентификация docker registry могут использоваться переменные `CI_JOB_TOKEN`, `CI_REGISTRY`, если они не переопределяются пользователем вот так: `docker login --username gitlab-ci-token --password $CI_JOB_TOKEN $CI_REGISTRY`

вместо указания username/password можно указать путь до произвольного docker config-а через `DAPP_DOCKER_CONFIG`.

для определения CI проверяется наличие переменной окружения `GITLAB_CI` или `TRAVIS`

`DAPP_HELM_RELEASE_NAME` переопределяет release name при deploy

`DAPP_DIMG_CLEANUP_REGISTRY_PASSWORD` специальный token для очистки registry (`dapp dimg cleanup repo`)

`DAPP_SLUG_V2` активирует схему slug-а с лимитом в 53 символа (такой лимит у имени release helm-а)

все переменные окружение с префиксом `CI_` прокидываются в helm-шаблоны  (`.Values.global.ci.CI_...`)

`ANSIBLE_ARGS` — прокидывается во все стадии с ansible и добавляется в командную строку к ansible-playbook

#### Параметры при схеме тегирования `--tag-build-id`

Тег формируется из переменных среды:

* `CI_BUILD_ID`;
* `TRAVIS_BUILD_NUMBER`.

#### Параметры при схеме тегирования `--tag-ci`

Тег формируется из переменных среды:

* `CI_BUILD_REF_NAME`, `CI_BUILD_TAG`;
* `TRAVIS_BRANCH`, `TRAVIS_TAG`.

#### Прочие параметры

Если сомневаетесь, есть ли параметр или нет, можете решиться [посмотреть исходные коды](https://github.com/flant/dapp/search?l=Ruby&p=1&q=ENV+path%3Alib)



## What's next

---
title: Gitlab CI/CD integration
sidebar: how_to
permalink: how_to/gitlab_ci_cd_integration.html
---

## Objectives

Setup CI/CD process using GitLab CI and dapp.

## Before you begin

This HowTo assumes you have:
* Kubernetes cluster and the kubectl CLI tool configured to communicate with cluster
* Server with GitLab above 10.x version (or account on [SaaS GitLab](https://gitlab.com/))
* Docker registry (GitLab embedded or somthere else)
* Host for build node (optional)
* An application you can successfully build and deploy with dapp

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

You need to setup gitlab runners with only two tags - build and deploy respectively for build stage and deploy stage. Cleanup will use both runners and don't need separate runners or nodes.

Build node needs an access to git repository of the application and to the docker registry, while deploy node additionly needs an access to the kubernetes cluster.

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

    You need to [install latest dapp]({{ site.baseurl }}/installation.html) for `gitlab-runner` user on both nodes.

### Setup deploy runner

Deploy runner need [helm](https://helm.sh/) and an access to a kubernetes cluster through kubectl. Easy way is to use master kubernetes node for deploy.

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
1. Install helm plugin `template` under `gitlab-runner` user
    ```
sudo su - gitlab-runner -c 'mkdir -p .helm/plugins &&
helm plugin install https://github.com/technosophos/helm-template'
```
1. Copy kubectl config to `gitlab-runner` user
    ```
mkdir -p /home/gitlab-runner/.kube &&
sudo cp -i /etc/kubernetes/admin.conf /home/gitlab-runner/.kube/config &&
sudo chown -R gitlab-runner:gitlab-runner /home/gitlab-runner/.kube
```

## Pipeline

When you have working build and deploy runners, you are ready to setup GitLab pipeline.

When GitLab starts job it sets list of [environments](https://docs.gitlab.com/ee/ci/variables/README.html) and we will use some of them.

Create `.gitlab-ci.yml` file in the project's root directory and add the following lines:

```yaml
variables:
  ## we will use this environment later as the name of kubernetes namespace for deploying application
  CI_NAMESPACE: ${CI_PROJECT_NAME}-${CI_ENVIRONMENT_SLUG}

stages:
  - build
  - deploy
  - cleanup_registry
  - cleanup_builder
```

We've defined stages:
- `build` -  stage for building application images;
- `deploy` - stage for deploying builded images on a stage, test, review, production or other environment;
- `cleanup_registry` - stage for cleaning up registry;
- `cleanup_builder` - stage for cleaning up dapp cache on build node.

> The ordering of elements in stages is important because it defines the ordering of jobs' execution.

### Build stage

Add the following lines to `.gitlab-ci.yml` file:

```yaml
Build:
  stage: build
  script:
    ## used for debugging
    - dapp --version; pwd; set -x
    ## Always use "bp" option instead separate "build" and "push"
    ## It is important to use --tag-ci, --tag-branch or --tag-commit options otherwise cleanup won't work.
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

For registry authorization on push/pull operations dapp use `CI_JOB_TOKEN` GitLab environment (see more about [GitLab CI job permissions model](https://docs.gitlab.com/ee/user/project/new_ci_build_permissions_model.html)) and this is the most recommended way you to use (see more about [dapp registry  authorization]({{ site.baseurl }}/registry_authorization.html)). To determine docker registry address dapp use `CI_REGISTRY` GitLab environment. In simple case, when you use GitLab with enabled container registry in it, you needn't to do anything for authorization.
> If you want that dapp won't use `CI_JOB_TOKEN` and `CI_REGISTRY` you can manually login under gitlab-runner user using `docker login --username <registry_username> --password <registry_password_or_token> <registry_address>`, or you can define `DAPP_DOCKER_CONFIG` environment variable which points to docker config file.

### Deploy stage

Set of environments in Deploy stage depends on you needs, but usually it includes:
- Review environment. It is a dynamic (or so called temporary) environment for taking first look on the result of development by developers. This environment will be deleted (stopped) after branch deletion in the repository or in case of manual environment stop.
- Test environment. Test environment may used by developer when he ready to show his work. On test environment ones can manual deploy application from any branches or tags.
- Stage environment. Stage environment may used for final tests of the application, and deploy can proceed automatically after merging into master branch (but this is not a rule).
- Production environment. Production environment is the final environment in pipeline. On production environment should be deployed only production ready version of the application. We assume that on production environment can be deployed only tags, and only after manual action.

Of course, parts of CI/CD process described above is not a rules and you can have your own.

First of all we define a template for the deploy jobs - this will decrease size of the `.gitlab-ci.yml` and will make it more readable. We will use this template in every deploy stage further.

Add the following lines to `.gitlab-ci.yml` file:

```yaml
.base_deploy: &base_deploy
  stage: deploy
  script:
    ## create k8s namespace we will use if it doesn't exist.
    - kubectl get ns ${CI_NAMESPACE} || kubectl create namespace ${CI_NAMESPACE}
    ## If your application use private registry, you have to:
    ## 1. create appropriate secret with name registrysecret in namespace kube-system of your k8s cluster
    ## 2. uncomment following lines:
    ##- kubectl get secret registrysecret -n kube-system -o json |
    ##                  jq ".metadata.namespace = \"${CI_NAMESPACE}\"|
    ##                  del(.metadata.annotations,.metadata.creationTimestamp,.metadata.resourceVersion,.metadata.selfLink,.metadata.uid)" |
    ##                  kubectl apply -f -
    - dapp --version; pwd; set -x
    ## Next command makes deploy and will be discussed further
    - dapp kube deploy
      --tag-ci
      --namespace ${CI_NAMESPACE}
      --set "global.env=${CI_ENVIRONMENT_SLUG}"
      --set "global.ci_url=$(echo ${CI_ENVIRONMENT_URL} | cut -d / -f 3)"
      ${CI_REGISTRY_IMAGE}
  ## It is important that the deploy stage depends on the build stage. If the build stage fails, deploy stage should not start.
  dependencies:
    - Build
  ## We need to use deploy runner, because dapp needs to interact with the kubectl
  tags:
    - deploy
```

Pay attention on `dapp kube deploy` command. It is the main step in deploying the application and note that:
- it is important to use `--tag-ci`, `--tag-branch` or `--tag-commit` options otherwise cleanup won't work;
- we use `CI_NAMESPACE` variable, defined at the top of the `.gitlab-ci.yml` file (it is not one of the GitLab [environments](https://docs.gitlab.com/ee/ci/variables/README.html))
- we passed `global.env` parameter, which will contains the name of the environment. You can access it in `helm` templates as `.Values.global.env` in Go-template's blocks, to configure deployment of your application according to the environment.
- we passed `global.ci_url` parameter, which will contains url of the environment. You can use it in your `helm` templates e.g. to configure ingress.


#### Review

As it was said erlier, review environment - is a dynamic (or temporary, or developer) environment for taking first look on the result of development by developers.

Add the following lines to `.gitlab-ci.yml` file:

```yaml
Review:
  <<: *base_deploy
  environment:
    name: review/${CI_COMMIT_REF_SLUG}
    ## Of course, you need to change domain suffix (`kube.DOMAIN`) of the url if you want to use it in you helm templates.
    url: http://${CI_PROJECT_NAME}-${CI_COMMIT_REF_SLUG}.kube.DOMAIN
    on_stop: Stop review
  only:
    - branches
  except:
    - master
    - schedules

Stop review:
  stage: deploy
  script:
    - dapp --version; pwd; set -x
    - dapp kube dismiss --namespace ${CI_NAMESPACE} --with-namespace
  environment:
    name: review/${CI_COMMIT_REF_SLUG}
    action: stop
  tags:
    - deploy
  only:
    - branches
  except:
    - master
    - schedules
  when: manual
```

We've defined two jobs:
1. Review.
    In this job we set name of the environment based on CI_COMMIT_REF_SLUG GitLab variable. For every branch gitlab will create uniq enviroment.

    The url parameter of the job you can use in you helm templates to setup e.g. ingress.

    Name of the kubernetes namespace will be equal CI_NAMESPACE (defined in dapp parameters in `base_deploy` template).    
2. Stop review.
    In this job, dapp will delete helm release in namespace CI_NAMESPACE and delete namespace itself (see more about [dapp kube dismiss]({{ site.baseurl }}/kube_dismiss.html)). This job will be available for manual run and also in will run by GitLab in case of e.g branch deletion.

Review jobs needn't to run on pushes to git master branch, because review environment is for delevopers.

As a result, you can stop this environment manually after deploying application on it, or GitLab will stop this environment when you merge your branch into master with source branch deletion enabled.

#### Test

We decide to don't give an example of test environment in this howto, because test environment is very similar to stage environment (see below). Try to describe test environment by yourself and we hope you will get a pleasure.

#### Stage

As you may remember, we need to deploy to stage environment only code from master branch and we allow automatic deploy.

Add the following lines to `.gitlab-ci.yml` file:

```
Deploy to Stage:
  <<: *base_deploy
  environment:
    name: stage
    url: http://${CI_PROJECT_NAME}-${CI_COMMIT_REF_SLUG}.kube.DOMAIN
  only:
    - master
  except:
    - schedules
```

We use `base_deploy` template and define only unique to stage environment variables such as - enviroment name and url. Because of this approach we get small and readable job description and as a result - more compact and readable `gitlab-ci.yml`.

#### Production

Production is the last and important environment! We only deploy tags on production environment and only by manual action (maybe at night?).

Add the following lines to `.gitlab-ci.yml` file:

```
Deploy to Production:
  <<: *base_deploy
  environment:
    name: production
    url: http://www.company.my
  only:
    - tags
  when: manual
  except:
    - schedules
```

Pay attention to `environment.url` - as we deploy application to production (to public access), we definitely have a static domain for it. We simply write it here and also  use in helm templates as `.Values.global.ci_url` (see definition of `base_deploy` template earlie).

### Cleanup stages

Dapp has an efficient cleanup functionality which can help you to avoid overflow registry and disk space on build nodes. You can read more about dapp cleanup functionality [here]({{ site.baseurl }}/cleanup.html).

In the results of dapp works we have an images in a registry and a build cache. Build cache exists only on build node and to the registry dapp push only builded images.

There are two stages - `cleanup_registry` and `cleanup_builder`, in `gitlab-cy.yml` for cleanup process. Every stage has only one job in it and order of stage definition (see `stages` list in top of the gitlab-ci.yml) is important.

First step in cleanup process is to clean registry from unused images (builded from stale or deleted branches and so on - see more [about dapp cleanup]({{ site.baseurl }}/cleanup.html)). This work will be done on the `cleanup_registry` stage. On this stage, dapp connect to the registry and to the kubernetes cluster. That is why on this stage we need to use deploy runner. From kubernetes cluster dapp gets info about images are currently used by pods.

Second step - is to cleanup cache on build node **after** registry has been cleaned. The important word is - after, because dapp will use info from registry to cleanup build cache, and if you haven't cleaned registry you'll not get an efficiently cleaned build cache. That's why important that `cleanup_builder` stage start after `cleanup_registry` stage.

Add the following lines to `.gitlab-ci.yml` file:

```
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

To use cleanup you should create `Personal Access Token` with necessary rigths and put it into the `DAPP_DIMG_CLEANUP_REGISTRY_PASSWORD` enviroment variable. You can simply put this variable in GitLab variables of your project. To do this, go to your project in GitLab Web interface, then open `Settings` -> `CI/CD` and expand `Variables`. Then you can create a new variable with a key `DAPP_DIMG_CLEANUP_REGISTRY_PASSWORD` and a value consisting `Personal Access Token`.

For demo project simply create `Personal Access Token` for your account. To do this, in GitLab go to your settings, then open `Access Token` section. Fill token name, make check in Scope on `api` and click `Create personal access token` - you'll get the `Personal Access Token`.

As you see, both stages will start only by schedules. You can define schedule in `CI/CD` -> `Schedules` section of your project in GitLab Web interface. Push `New schedule` button, fill description, define cron pattern, leave the master branch in target branch (because it doesn't affect on cleanup), check on Active (if it's not checked) and save pipeline schedule. That's all!

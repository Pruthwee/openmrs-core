# OpenMRS (openmrs-cont) - Deployment guide for AWS EKS

This guide covers the containerization of the OpenMRS core (a multi-module Maven build, Java 21, `openmrs.war` served by Tomcat 11) and its deployment to **AWS EKS** with `kubectl`.

Names used below: image, compose service, namespace and Kubernetes objects are all called `openmrs-cont` (`openmrs-cont-service`, `openmrs-cont-ingress`, `openmrs-cont-secrets`).

## 1. Prerequisites and system requirements

| Tool | Use |
| --- | --- |
| Docker 24+ (BuildKit) | build the image, run it locally |
| Docker Compose v2 | local run of the application container |
| AWS CLI v2 | ECR login, `aws eks update-kubeconfig` |
| kubectl (within one minor version of the cluster) | deploy and manage the workload |
| eksctl | create and manage the EKS cluster |
| Bash (Linux/macOS) or Windows `cmd` with PowerShell | the scripts under `scripts/` |

* A workstation with 4 CPU cores and 8 GB RAM is enough for the image build (the Maven build of all modules is the heavy part).
* At run time one pod requests 250m CPU / 512 Mi and is limited to 500m CPU / 1 Gi. OpenMRS starts slowly (Liquibase, Hibernate, module loading); give it more CPU and memory for the first start or for a large database.
* **External services** are not part of this repository and are reached through environment variables: a MariaDB / MySQL / PostgreSQL database (for example Amazon RDS) and, optionally, Elasticsearch.
* IAM permissions of the person or role that deploys: `ecr:GetAuthorizationToken`, `ecr:BatchCheckLayerAvailability`, `ecr:InitiateLayerUpload`, `ecr:UploadLayerPart`, `ecr:CompleteLayerUpload`, `ecr:PutImage`, `ecr:CreateRepository`, `ecr:DescribeRepositories`, `eks:DescribeCluster`, `eks:ListClusters`, plus an EKS access entry / `aws-auth` mapping that lets the identity create Namespaces, Secrets, Deployments, Services and Ingresses.

## 2. Local setup with Docker Compose

`docker-compose.yml` has exactly one service, the application. The database is an external service: start one yourself and point the variables at it.

```bash
export OMRS_DB_HOSTNAME=host.docker.internal      # or the address of your database
export OMRS_DB_PASSWORD='<database password>'
export OMRS_ADMIN_USER_PASSWORD='<password of the OpenMRS admin user>'
docker compose -f docker-compose.yml up --build
```

* Use `-f docker-compose.yml`: the repository also holds `docker-compose.override.yml` (developer set-up for the old multi-service layout), which Compose would otherwise merge in.
* The credentials are read from the environment of the shell (`${OMRS_DB_PASSWORD:?set OMRS_DB_PASSWORD}`); nothing is written into the file.
* Open `http://localhost:8080/openmrs`. The first start can take several minutes.
* Data (modules, configuration, complex obs, Lucene index) is stored in the `openmrs-data` volume mounted at `/openmrs/data`.

## 3. Build and push the image

Run from the **repository root**:

```bash
./scripts/build-push.sh          # Linux / macOS
scripts\build-push.bat           # Windows
```

The script asks for the registry (1. AWS ECR, 2. Docker Hub), then only the details of the chosen one (AWS account ID, region and repository, or Docker Hub user, password and repository), then `IMAGE_TAG` (empty means `latest`). It runs `docker build -f Dockerfile -t <registry>/<repo>:<tag> .`, logs in (for ECR with `aws ecr get-login-password ... | docker login --username AWS --password-stdin`), creates the ECR repository when it is missing and pushes the image. The last line printed is the full image URI that `deploy-image` asks for.

### What the Dockerfile does

1. **Build stage** `maven:3.9.4-eclipse-temurin-21`: `COPY . .`, `mvn clean install -N -DskipTests` (parent POM), `mvn clean package -DskipTests` (all modules, producing `webapp/target/openmrs.war`), then downloads Tomcat 11.0.11 (SHA-512 verified) and lays out `/openmrs` as `startup.sh` expects.
2. **Runtime stage** `amazoncorretto:21`: copies Tomcat and `/openmrs` (no package manager is used), runs as the non-root user `1001`, exposes `8080` and starts `/openmrs/startup.sh`, which waits for the database, writes Tomcat's `setenv.sh` from the environment and `exec`s `catalina.sh run` so the JVM is the process that receives SIGTERM.

The previous multi-target Dockerfile (dev stage, Tini, `curl` health check) was replaced by this production one. The Dockerfile has no `HEALTHCHECK`; Kubernetes probes the application's own health endpoints.

## 4. Deploy to AWS EKS

### 4.1 Cluster setup (once)

```bash
eksctl create cluster --name openmrs-cluster --region us-east-1 --nodegroup-name workers \
  --node-type m5.large --nodes 2 --nodes-min 2 --nodes-max 4 --managed
aws eks update-kubeconfig --region us-east-1 --name openmrs-cluster
kubectl cluster-info
```

The Ingress uses the **AWS Load Balancer Controller** (annotations `kubernetes.io/ingress.class: alb`, `alb.ingress.kubernetes.io/scheme: internet-facing`). Install it in the cluster (IAM OIDC provider, IAM policy, service account, Helm chart `eks/aws-load-balancer-controller`) before the first deployment, see the AWS documentation "Installing the AWS Load Balancer Controller add-on".

### 4.2 Deploy

```bash
./scripts/deploy-image.sh        # Linux / macOS
scripts\deploy-image.bat         # Windows
```

The script asks for the AWS region, the EKS cluster name, the image URI and each configuration value ("Enter value for `<variable>` (or press Enter to skip)"), and for the two credentials without echoing them. Then it:

1. runs `aws eks update-kubeconfig --region <region> --name <cluster>` and `kubectl cluster-info`;
2. applies `kubernetes/namespace.yaml`;
3. creates the Secret `openmrs-cont-secrets` with `kubectl create secret generic ... --dry-run=client -o yaml | kubectl apply -f -`;
4. replaces the `"{{...}}"` placeholders of `kubernetes/deployment.yaml` (it puts the template back when it ends);
5. applies `deployment.yaml`, `service.yaml`, `ingress.yaml`, waits with `kubectl rollout status deployment/openmrs-cont -n openmrs-cont`, shows `kubectl get pods,svc,ingress -n openmrs-cont` and the load balancer address; on a failure it prints the rollback commands.

### 4.3 The manifests

| File | Content |
| --- | --- |
| `kubernetes/namespace.yaml` | Namespace `openmrs-cont`, label `name: openmrs-cont`. |
| `kubernetes/deployment.yaml` | Deployment `openmrs-cont`, 2 replicas, container `openmrs-cont` with `image: "{{IMAGE_URI}}"`, port 8080, requests 250m / 512Mi, limits 500m / 1Gi, runs as UID 1001 (non-root), liveness probe `/openmrs/health/alive`, readiness probe `/openmrs/health/started`, environment placeholders, the two credentials from the Secret, and an `emptyDir` at `/openmrs/data`. |
| `kubernetes/service.yaml` | Service `openmrs-cont-service`, ClusterIP, port 80 to container port 8080, selector `app: openmrs-cont`. |
| `kubernetes/ingress.yaml` | Ingress `openmrs-cont-ingress` for the AWS Load Balancer Controller, host `openmrs-cont.example.com`, path `/` (Prefix) to `openmrs-cont-service:80`, ALB health check on `/openmrs/health/alive`. |

Change the host `openmrs-cont.example.com` to your DNS name (and add TLS annotations / a certificate ARN for HTTPS) before production use.

> **Shared state:** the manifests use an `emptyDir` for `/openmrs/data`, so modules, configuration and the search index are per pod and lost when the pod is replaced. For production mount a shared `PersistentVolumeClaim` (Amazon EFS with the EFS CSI driver, `ReadWriteMany`) at `/openmrs/data`, and use Elasticsearch (`OMRS_SEARCH=elasticsearch`) when running more than one replica. OpenMRS also keeps user sessions in the pod's memory: use ALB stickiness (`alb.ingress.kubernetes.io/target-group-attributes: stickiness.enabled=true,stickiness.type=lb_cookie`) or one replica until sessions are externalized.

## 5. Configuration management and environment variables

| Variable | Meaning | Default in the scripts |
| --- | --- | --- |
| `OMRS_DB` | database type: `mariadb`, `mysql`, `postgresql` | `mariadb` |
| `OMRS_DB_HOSTNAME`, `OMRS_DB_PORT`, `OMRS_DB_NAME` | database location (an Amazon RDS endpoint, for example) | `localhost`, `3306`, `openmrs` |
| `OMRS_DB_USERNAME` | database user | `openmrs` |
| `OMRS_DB_PASSWORD` | database password, **Secret** key | required |
| `OMRS_ADMIN_USER_PASSWORD` | password of the OpenMRS `admin` user, **Secret** key | required |
| `OMRS_ADMIN_PASSWORD_LOCKED` | lock the admin password in the UI | `true` |
| `OMRS_CREATE_TABLES`, `OMRS_AUTO_UPDATE_DATABASE` | schema creation / update at start-up | `true` |
| `OMRS_SEARCH`, `OMRS_SEARCH_ES_URIS` | `lucene` (default) or `elasticsearch` and its URIs | `lucene`, empty |
| `OMRS_JAVA_MEMORY_OPTS` | JVM flags that `startup.sh` writes into Tomcat's `CATALINA_OPTS` | set in the image, see section 7 |
| `OMRS_HOME`, `OMRS_WEBAPP_NAME` | OpenMRS home (`/openmrs`) and webapp name (`openmrs`) | image defaults |
| `OPENMRS_APPLICATION_DATA_DIRECTORY_FALLBACK` | fallback application data directory on Unix (blocker fix for cz-java-0057) | `/var/lib` |
| `OMRS_HIBERNATE_DEFAULT_PROPERTIES_FILE` | optional file (for example from a ConfigMap) that replaces the bundled `hibernate.default.properties` (blocker fix for cz-java-0078) | classpath file |
| `OMRS_LOCAL_DB_HOST_IP` | loopback address the installation wizard treats as local (blocker fix for cz-java-0062) | `127.0.0.1` |

`startup-init.sh` lists all the other `OMRS_*` variables. Non-sensitive values live in the Deployment (or a ConfigMap you add); credentials always come from the Secret `openmrs-cont-secrets`.

### Variables read by the code itself

| Variable | Used by | Default |
|---|---|---|
| `OPENMRS_APPLICATION_DATA_DIRECTORY_FALLBACK` | `OpenmrsConstants` - fallback application data directory on Unix | `/var/lib` |
| `OMRS_LOCAL_DB_HOST_IP` | `InitializationFilter` - address treated as the local database host | `127.0.0.1` |
| `OMRS_HIBERNATE_DEFAULT_PROPERTIES_FILE` | `HibernateSessionFactoryBean` - path of a file (for example a mounted ConfigMap) used instead of the bundled `hibernate.default.properties` | the classpath file |
| `TEST_TMP_DIR`, `TEST_WEBAPP_REAL_PATH` | unit tests only | `/tmp`, `/usr/local/apache-tomcat-7.0.27/webapps/openmrs` |

## 6. Security considerations and best practices

* Credentials are never written in files: compose reads them from the shell, Kubernetes from `openmrs-cont-secrets`. Prefer AWS Secrets Manager with the External Secrets Operator or the Secrets Store CSI driver in production, and enable envelope encryption of Secrets on the cluster.
* **Shell defaults to review:** `startup-init.sh` still carries development defaults for `OMRS_DB_PASSWORD` and `OMRS_ADMIN_USER_PASSWORD` for the case that the variables are missing; the manifests and the compose file always set both, never rely on the defaults.
* The container runs as non-root (UID 1001, group 0); do not add privileged settings. Consider `readOnlyRootFilesystem` with writable `emptyDir` mounts for `/usr/local/tomcat/{logs,temp,work,webapps,bin}` after testing.
* Use a private ECR repository with image scanning on push; pin the image by tag or digest, not `latest`.
* Terminate TLS at the ALB with an ACM certificate; restrict the ALB (`alb.ingress.kubernetes.io/inbound-cidrs`) and the database security group to what is needed.
* OpenMRS stores patient data: encrypt the database and volumes at rest (RDS / EFS encryption) and review the OpenMRS security guidance.
* Run the pods in subnets with a restricted route to the internet and open the database port only from the node/pod security group.

## 7. Java notes

* **JVM settings.** The image sets `JAVA_OPTS="-Xmx512m -Xms256m -XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0"`. OpenMRS' `startup.sh` builds Tomcat's `setenv.sh` from `OMRS_JAVA_SERVER_OPTS` (as `JAVA_OPTS`) and `OMRS_JAVA_MEMORY_OPTS` (as `CATALINA_OPTS`), so the image also sets `OMRS_JAVA_MEMORY_OPTS` to the same flags plus `-XX:NewSize=128m`. When `-Xmx` is present it wins over `MaxRAMPercentage`. With the 1 Gi pod limit the 512 MB heap leaves room for metaspace, thread stacks, Lucene and direct buffers; for larger databases raise the limit and the heap together (for example limit 2 Gi, `-Xmx1024m`), keeping the heap at about 50-75 % of the limit, and set the new value in the Deployment's `env` as `OMRS_JAVA_MEMORY_OPTS`. `-XX:+UseContainerSupport` makes the JVM read the cgroup CPU and memory limits, so thread pools sized from `availableProcessors()` follow the pod's CPU limit. `TZ=UTC` and `LANG=C.UTF-8` are set; `-Dfile.encoding=UTF-8` comes from `OMRS_JAVA_SERVER_OPTS`.
* **Profiles.** OpenMRS is not a Spring Boot application (a Spring MVC WAR in Tomcat), so there is no `SPRING_PROFILES_ACTIVE`; behavior is configured through the `OMRS_*` variables, runtime properties (`openmrs-runtime.properties`, written by `startup-init.sh`) and global properties.
* **Health endpoints.** The application already has them (served by `StartupFilter`, no actuator is needed): `GET /openmrs/health/alive` returns 200 while OpenMRS is starting, in set-up or started and 503 otherwise (liveness probe and ALB health check); `GET /openmrs/health/started` returns 200 only when OpenMRS has completely started and 503 before (readiness probe). The probes have long initial delays (120 s / 90 s) because the first start runs the Liquibase changesets.
* **Graceful shutdown.** `startup.sh` `exec`s Tomcat, so SIGTERM from Kubernetes reaches the JVM; `terminationGracePeriodSeconds` is 60.

## 8. Troubleshooting

**Pod failures**
* `kubectl get pods -n openmrs-cont`, `kubectl describe pod <pod> -n openmrs-cont`, `kubectl logs <pod> -n openmrs-cont`.
* `ImagePullBackOff`: wrong image URI, or the node role lacks `AmazonEC2ContainerRegistryReadOnly`.
* `CrashLoopBackOff` / waiting forever: `startup.sh` waits for `OMRS_DB_HOSTNAME:OMRS_DB_PORT` (up to an hour); check the database address, security groups and credentials in the log.
* `OOMKilled`: raise the memory limit and the heap (section 7).
* Probes failing: the first start takes minutes; check `kubectl logs` for Liquibase progress before changing the delays.

**Service issues**
* `kubectl get endpoints openmrs-cont-service -n openmrs-cont` must list the pod IPs; empty means the pods are not ready or the selector `app: openmrs-cont` does not match.
* Test inside the cluster: `kubectl run -it --rm curl --image=curlimages/curl -n openmrs-cont -- curl -i http://openmrs-cont-service/openmrs/health/alive`.

**Ingress / EKS problems**
* `kubectl describe ingress openmrs-cont-ingress -n openmrs-cont`; no ADDRESS after a few minutes means the AWS Load Balancer Controller is not installed or lacks IAM permissions (`kubectl logs -n kube-system deploy/aws-load-balancer-controller`).
* Targets unhealthy in the ALB: the health check path must return 200 (`/openmrs/health/alive`), and the node/pod security groups must allow the ALB to reach port 8080.
* `aws eks update-kubeconfig` fails or `kubectl` says `Unauthorized`: check `aws sts get-caller-identity` and that the identity has an EKS access entry.

## 9. Scaling and management

* Scale manually: `kubectl scale deployment/openmrs-cont -n openmrs-cont --replicas=3` (see the note on shared state in section 4.3 first).
* Horizontal Pod Autoscaler (needs the metrics server):
  `kubectl autoscale deployment openmrs-cont -n openmrs-cont --cpu-percent=70 --min=2 --max=6`
* Rolling update: change the image with `kubectl set image deployment/openmrs-cont openmrs-cont=<new image URI> -n openmrs-cont` (or run `deploy-image` again); follow it with `kubectl rollout status deployment/openmrs-cont -n openmrs-cont`.
* Rollback: `kubectl rollout history deployment/openmrs-cont -n openmrs-cont`, `kubectl rollout undo deployment/openmrs-cont -n openmrs-cont` (or `--to-revision=<n>`).
* Node capacity: `eksctl scale nodegroup --cluster openmrs-cluster --name workers --nodes 3`, or use Karpenter / Cluster Autoscaler.
* Clean up: `kubectl delete namespace openmrs-cont` removes everything created by the scripts.

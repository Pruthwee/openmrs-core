@echo off & setlocal enabledelayedexpansion
rem Deploys the pushed OpenMRS image to AWS EKS with kubectl.
rem Run it from the repository root, scripts\deploy-image.bat

set "APP_NAME=openmrs-cont"
set "NAMESPACE=openmrs-cont"
set "SECRET_NAME=openmrs-cont-secrets"

echo === Deploy !APP_NAME! to AWS EKS ===

where aws >nul 2>&1
if !ERRORLEVEL! neq 0 (
  echo ERROR the AWS CLI is not installed or not in PATH
  exit /b 1
)
where kubectl >nul 2>&1
if !ERRORLEVEL! neq 0 (
  echo ERROR kubectl is not installed or not in PATH
  exit /b 1
)
where powershell >nul 2>&1
if !ERRORLEVEL! neq 0 (
  echo ERROR PowerShell is required to fill in the placeholders
  exit /b 1
)

for %%M in (namespace deployment service ingress) do (
  if not exist "kubernetes\%%M.yaml" (
    echo ERROR kubernetes\%%M.yaml not found, run this script from the repository root
    exit /b 1
  )
)

rem ---- Cluster details ----
set /p AWS_REGION="Enter the AWS region, for example us-east-1: "
set /p CLUSTER_NAME="Enter the EKS cluster name: "
set /p IMAGE_URI="Enter the image URI, registry and repository and tag as printed by build-push: "
if "!AWS_REGION!"=="" (
  echo ERROR the AWS region is required
  exit /b 1
)
if "!CLUSTER_NAME!"=="" (
  echo ERROR the cluster name is required
  exit /b 1
)
if "!IMAGE_URI!"=="" (
  echo ERROR the image URI is required
  exit /b 1
)

rem ---- Application configuration, a placeholder in kubernetes\deployment.yaml each ----
set "OMRS_DB=mariadb"
set /p OMRS_DB="Enter value for OMRS_DB (or press Enter to skip): "
if "!OMRS_DB!"=="" set "OMRS_DB=mariadb"
set "OMRS_DB_HOSTNAME=localhost"
set /p OMRS_DB_HOSTNAME="Enter value for OMRS_DB_HOSTNAME (or press Enter to skip): "
if "!OMRS_DB_HOSTNAME!"=="" set "OMRS_DB_HOSTNAME=localhost"
set "OMRS_DB_PORT=3306"
set /p OMRS_DB_PORT="Enter value for OMRS_DB_PORT (or press Enter to skip): "
if "!OMRS_DB_PORT!"=="" set "OMRS_DB_PORT=3306"
set "OMRS_DB_NAME=openmrs"
set /p OMRS_DB_NAME="Enter value for OMRS_DB_NAME (or press Enter to skip): "
if "!OMRS_DB_NAME!"=="" set "OMRS_DB_NAME=openmrs"
set "OMRS_DB_USERNAME=openmrs"
set /p OMRS_DB_USERNAME="Enter value for OMRS_DB_USERNAME (or press Enter to skip): "
if "!OMRS_DB_USERNAME!"=="" set "OMRS_DB_USERNAME=openmrs"
set "OMRS_ADMIN_PASSWORD_LOCKED=true"
set /p OMRS_ADMIN_PASSWORD_LOCKED="Enter value for OMRS_ADMIN_PASSWORD_LOCKED (or press Enter to skip): "
if "!OMRS_ADMIN_PASSWORD_LOCKED!"=="" set "OMRS_ADMIN_PASSWORD_LOCKED=true"
set "OMRS_CREATE_TABLES=true"
set /p OMRS_CREATE_TABLES="Enter value for OMRS_CREATE_TABLES (or press Enter to skip): "
if "!OMRS_CREATE_TABLES!"=="" set "OMRS_CREATE_TABLES=true"
set "OMRS_AUTO_UPDATE_DATABASE=true"
set /p OMRS_AUTO_UPDATE_DATABASE="Enter value for OMRS_AUTO_UPDATE_DATABASE (or press Enter to skip): "
if "!OMRS_AUTO_UPDATE_DATABASE!"=="" set "OMRS_AUTO_UPDATE_DATABASE=true"
set "OMRS_SEARCH=lucene"
set /p OMRS_SEARCH="Enter value for OMRS_SEARCH (or press Enter to skip): "
if "!OMRS_SEARCH!"=="" set "OMRS_SEARCH=lucene"
set "OMRS_SEARCH_ES_URIS="
set /p OMRS_SEARCH_ES_URIS="Enter value for OMRS_SEARCH_ES_URIS, only for elasticsearch (or press Enter to skip): "

rem ---- Credentials, read without echo through PowerShell ----
set "SECRET_TMP=%TEMP%\omrs_secret_value.txt"
powershell -NoProfile -Command "$s = Read-Host 'Enter value for OMRS_DB_PASSWORD' -AsSecureString; [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))" > "!SECRET_TMP!"
set /p OMRS_DB_PASSWORD=<"!SECRET_TMP!"
powershell -NoProfile -Command "$s = Read-Host 'Enter value for OMRS_ADMIN_USER_PASSWORD' -AsSecureString; [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))" > "!SECRET_TMP!"
set /p OMRS_ADMIN_USER_PASSWORD=<"!SECRET_TMP!"
del "!SECRET_TMP!" >nul 2>&1
if "!OMRS_DB_PASSWORD!"=="" (
  echo ERROR OMRS_DB_PASSWORD is required
  exit /b 1
)
if "!OMRS_ADMIN_USER_PASSWORD!"=="" (
  echo ERROR OMRS_ADMIN_USER_PASSWORD is required
  exit /b 1
)

rem ---- kubectl for the EKS cluster ----
echo Configuring kubectl for cluster !CLUSTER_NAME! in !AWS_REGION!
aws eks update-kubeconfig --region !AWS_REGION! --name !CLUSTER_NAME!
if !ERRORLEVEL! neq 0 (
  echo ERROR aws eks update-kubeconfig failed, check the AWS credentials, the region and the cluster name
  exit /b 1
)
kubectl cluster-info
if !ERRORLEVEL! neq 0 (
  echo ERROR kubectl cannot reach the cluster
  exit /b 1
)

rem ---- Namespace and Secret ----
echo Applying kubernetes\namespace.yaml
kubectl apply -f kubernetes\namespace.yaml
if !ERRORLEVEL! neq 0 (
  echo ERROR could not apply the namespace
  exit /b 1
)

echo Creating the Secret !SECRET_NAME!
kubectl create secret generic !SECRET_NAME! -n !NAMESPACE! --from-literal=OMRS_DB_PASSWORD="!OMRS_DB_PASSWORD!" --from-literal=OMRS_ADMIN_USER_PASSWORD="!OMRS_ADMIN_USER_PASSWORD!" --dry-run=client -o yaml | kubectl apply -f -
if !ERRORLEVEL! neq 0 (
  echo ERROR could not create the Secret
  exit /b 1
)

rem ---- Placeholders, the template is kept and restored at the end ----
copy /y kubernetes\deployment.yaml kubernetes\deployment.yaml.orig >nul
powershell -NoProfile -Command "$f = 'kubernetes\deployment.yaml'; $c = Get-Content -Raw $f; foreach ($n in 'IMAGE_URI','NAMESPACE','OMRS_DB','OMRS_DB_HOSTNAME','OMRS_DB_PORT','OMRS_DB_NAME','OMRS_DB_USERNAME','OMRS_ADMIN_PASSWORD_LOCKED','OMRS_CREATE_TABLES','OMRS_AUTO_UPDATE_DATABASE','OMRS_SEARCH','OMRS_SEARCH_ES_URIS') { $v = [Environment]::GetEnvironmentVariable($n); if ($v -eq $null) { $v = '' }; $c = $c.Replace('{{' + $n + '}}', $v) }; Set-Content -NoNewline -Path $f -Value $c"
if !ERRORLEVEL! neq 0 (
  echo ERROR could not fill in the placeholders
  copy /y kubernetes\deployment.yaml.orig kubernetes\deployment.yaml >nul
  del kubernetes\deployment.yaml.orig >nul 2>&1
  exit /b 1
)

rem ---- Deploy ----
echo Applying kubernetes\deployment.yaml
kubectl apply -f kubernetes\deployment.yaml
set "DEPLOY_RESULT=!ERRORLEVEL!"
copy /y kubernetes\deployment.yaml.orig kubernetes\deployment.yaml >nul
del kubernetes\deployment.yaml.orig >nul 2>&1
if !DEPLOY_RESULT! neq 0 (
  echo ERROR could not apply the deployment
  goto :rollback_help
)
echo Applying kubernetes\service.yaml
kubectl apply -f kubernetes\service.yaml
if !ERRORLEVEL! neq 0 (
  echo ERROR could not apply the service
  goto :rollback_help
)
echo Applying kubernetes\ingress.yaml
kubectl apply -f kubernetes\ingress.yaml
if !ERRORLEVEL! neq 0 (
  echo ERROR could not apply the ingress, is the AWS Load Balancer Controller installed
  goto :rollback_help
)

echo Waiting for the rollout, OpenMRS needs several minutes on first start
kubectl rollout status deployment/!APP_NAME! -n !NAMESPACE! --timeout=900s
if !ERRORLEVEL! neq 0 (
  echo ERROR the rollout did not complete
  goto :rollback_help
)

kubectl get pods,svc,ingress -n !NAMESPACE!

set "INGRESS_HOST="
kubectl get ingress !APP_NAME!-ingress -n !NAMESPACE! -o jsonpath="{.status.loadBalancer.ingress[0].hostname}" > "%TEMP%\omrs_ingress_host.txt" 2>nul
set /p INGRESS_HOST=<"%TEMP%\omrs_ingress_host.txt"
del "%TEMP%\omrs_ingress_host.txt" >nul 2>&1
if not "!INGRESS_HOST!"=="" (
  echo Application address, open it with http in front and /openmrs behind
  echo !INGRESS_HOST!
  echo Send the Host header !APP_NAME!.example.com or point that DNS name at the load balancer
) else (
  echo The load balancer address is not assigned yet. Check later with
  echo   kubectl get ingress !APP_NAME!-ingress -n !NAMESPACE!
)
echo Deployment finished
endlocal
exit /b 0

:rollback_help
echo.
echo The deployment failed. To roll back to the previous revision
echo   kubectl rollout undo deployment/!APP_NAME! -n !NAMESPACE!
echo To inspect it
echo   kubectl describe deployment/!APP_NAME! -n !NAMESPACE!
echo   kubectl logs deployment/!APP_NAME! -n !NAMESPACE!
echo   kubectl get events -n !NAMESPACE! --sort-by=.lastTimestamp
endlocal
exit /b 1

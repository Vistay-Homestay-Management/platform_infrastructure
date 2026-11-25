import groovy.transform.Field

@Field Map<String, List<String>> REPO_SERVICES = [
    'service_authentication': ['authentication'],
    'service_user'          : ['user'],
    'service_property'      : ['property'],
    'service_booking'       : ['booking'],
    'service_finance'       : ['finance'],
    'service_payment'       : ['payment'],
    'service_notification'  : ['notification'],
    'service_media'         : ['media'],
    'service_operations'    : ['operations'],
    'service_ota'           : ['ota'],
    'service_data_warehouse': ['warehouse'],
    'frontend_admin'        : ['frontend-admin'],
    'frontend_customer'     : ['frontend-customer'],
    'frontend_host'         : ['frontend-host'],
]

@Field List<String> ALL_REPOS = ['platform_contracts', 'platform_infrastructure'] + REPO_SERVICES.keySet().toList()

@Field Map pipelineState = [
    changedRepos   : [],
    changedServices: [],
    reposToVerify  : [],
    fullDeploy     : false,
]

String sharedWorkspace() {
    return env.VISTAY_SHARED_WORKSPACE ?: env.WORKSPACE
}

String deployRoot() {
    return "${sharedWorkspace()}/deploy"
}

String repositoryPath(String repo) {
    return "${deployRoot()}/${repo}"
}

String composeCommand(String profile) {
    return "docker compose -f compose.yaml -f compose.full.yaml --env-file .env --profile ${profile}"
}

boolean syncRepository(String org, String repo, String branch) {
    String path = repositoryPath(repo)

    if (!fileExists("${path}/.git")) {
        sh """
            set -eu
            mkdir -p "${deployRoot()}"
            rm -rf "${path}"
            git clone --recurse-submodules --branch "${branch}" \
                "https://github.com/${org}/${repo}.git" "${path}"
        """
        return true
    }

    String before = sh(script: "git -C \"${path}\" rev-parse HEAD", returnStdout: true).trim()
    sh """
        set -eu
        find "${path}/.git" -name '*.lock' -delete
        git -C "${path}" fetch --prune origin "+refs/heads/${branch}:refs/remotes/origin/${branch}"
        git -C "${path}" checkout -f -B "${branch}" "origin/${branch}"
        git -C "${path}" reset --hard "origin/${branch}"
        git -C "${path}" clean -ffd -e .env -e .secrets -e certs/generated
        git -C "${path}" submodule sync --recursive
        git -C "${path}" submodule update --init --recursive
    """
    String after = sh(script: "git -C \"${path}\" rev-parse HEAD", returnStdout: true).trim()
    return before != after
}

void runRepositoryChecks(String repo) {
    String path = repositoryPath(repo)

    if (repo.startsWith('service_')) {
        withEnv(['JAVA_HOME=/opt/java/openjdk21', 'PATH+JDK21=/opt/java/openjdk21/bin']) {
            dir(path) {
                sh 'chmod +x gradlew'
                if (params.RUN_TESTS) {
                    sh './gradlew test --no-daemon'
                } else {
                    sh './gradlew bootJar --no-daemon'
                }
            }
        }
        return
    }

    if (repo == 'platform_contracts') {
        dir(path) {
            sh 'npm ci --no-audit --no-fund'
            sh 'npm test'
        }
        return
    }

    if (repo.startsWith('frontend_')) {
        dir(path) {
            sh 'npm ci --no-audit --no-fund'
            if (repo == 'frontend_admin') {
                sh 'npm run typecheck'
            }
            sh 'npm run build'
            sh 'npm run lint --if-present'
            if (repo == 'frontend_admin' && params.RUN_TESTS) {
                sh 'npm test'
            }
        }
    }
}

void runInfrastructureChecks() {
    dir(repositoryPath('platform_infrastructure')) {
        sh 'docker compose --env-file .env.example -f compose.yaml -f compose.full.yaml --profile full config -q'
        sh 'pwsh -NoProfile -File ./scripts/Test-EdgeTopology.ps1 -EnvFile .env.example -IncludeFullStack'
        sh 'pwsh -NoProfile -File ./scripts/Test-HostEdgeTopology.ps1'
        sh 'pwsh -NoProfile -File ./scripts/Test-KeycloakContract.ps1 -EnvFile .env.example'
        sh 'pwsh -NoProfile -File ./scripts/Test-Observability.ps1 -EnvFile .env.example -StaticOnly'
    }
}

String readEnvironmentValue(String envPath, String key) {
    return sh(
        script: "grep -E '^${key}=' \"${envPath}\" | head -n1 | cut -d= -f2-",
        returnStdout: true
    ).trim()
}

void ensureEnvironmentFile(String infraPath) {
    String envPath = "${infraPath}/.env"
    if (fileExists(envPath)) {
        return
    }

    String credentialId = params.ENV_FILE_CREDENTIAL?.trim()
    if (!credentialId) {
        error("Missing ${envPath}. Provision it on the deploy host or set ENV_FILE_CREDENTIAL to a Jenkins secret-file credential.")
    }

    withCredentials([file(credentialsId: credentialId, variable: 'VISTAY_ENV_FILE')]) {
        sh "cp \"\$VISTAY_ENV_FILE\" \"${envPath}\" && chmod 600 \"${envPath}\""
    }
}

void ensureCertificates(String infraPath) {
    if (fileExists("${infraPath}/certs/generated/kafka/broker/kafka.keystore.jks") &&
        fileExists("${infraPath}/certs/generated/grpc/user-server/server.crt")) {
        return
    }

    String envPath = "${infraPath}/.env"
    String storePassword = readEnvironmentValue(envPath, 'KAFKA_STORE_PASSWORD')
    if (!storePassword) {
        error("KAFKA_STORE_PASSWORD is missing from ${envPath}; cannot generate development certificates.")
    }

    wrap([$class: 'MaskPasswordsBuildWrapper', varPasswordPairs: [[var: 'VISTAY_KAFKA_STORE_PASSWORD', password: storePassword]]]) {
        withEnv(["VISTAY_KAFKA_STORE_PASSWORD=${storePassword}"]) {
            dir(infraPath) {
                sh 'pwsh -NoProfile -File ./scripts/Generate-DevCertificates.ps1 -StorePassword "$VISTAY_KAFKA_STORE_PASSWORD"'
            }
        }
    }
}

boolean isStackRunning(String infraPath) {
    if (!fileExists("${infraPath}/.env")) {
        return false
    }

    String output = sh(
        script: "cd \"${infraPath}\" && ${composeCommand('full')} ps -q 2>/dev/null | wc -l",
        returnStdout: true
    ).trim()
    return (output as Integer) > 0
}

void deployStack(String infraPath, List<String> services, boolean full, boolean buildAll, String profile) {
    dir(infraPath) {
        String compose = composeCommand(profile)

        if (full) {
            if (!buildAll && !services.isEmpty()) {
                sh "${compose} build ${services.unique().join(' ')}"
            }
            sh "${compose} up -d ${buildAll ? '--build' : ''} --wait --wait-timeout 600 --remove-orphans"
        } else {
            String target = services.unique().join(' ')
            sh "${compose} build ${target}"
            sh "${compose} up -d --no-deps --wait --wait-timeout 300 ${target}"
        }

        sh "${compose} ps"
        sh "${compose} exec -T nginx wget -qO- http://127.0.0.1:8080/healthz"
    }
}

pipeline {
    agent any

    options {
        timestamps()
        ansiColor('xterm')
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '30', artifactNumToKeepStr: '10'))
        timeout(time: 90, unit: 'MINUTES')
        skipDefaultCheckout(true)
    }

    parameters {
        string(name: 'GITHUB_ORG', defaultValue: 'Vistay-Homestay-Management', description: 'GitHub organization that owns the ViStay repositories.')
        string(name: 'BRANCH', defaultValue: 'dev', description: 'Branch to deploy for every repository.')
        choice(name: 'DEPLOY_MODE', choices: ['changed', 'full'], description: 'Deploy only changed services or rebuild and deploy the whole stack.')
        booleanParam(name: 'RUN_TESTS', defaultValue: true, description: 'Run repository test suites before deploying.')
        booleanParam(name: 'VERIFY_ALL', defaultValue: false, description: 'Verify and analyze every repository, even when Git reports no changes.')
        booleanParam(name: 'DEPLOY_ENABLED', defaultValue: false, description: 'Deploy with Docker Compose. Keep false for verify and SonarQube-only runs.')
        string(name: 'COMPOSE_PROFILE', defaultValue: 'full', description: 'Docker Compose profile used for deployment.')
        string(name: 'ENV_FILE_CREDENTIAL', defaultValue: '', description: 'Optional Jenkins secret-file credential containing platform_infrastructure/.env.')
    }

    stages {
        stage('Sync repositories') {
            steps {
                script {
                    ws(sharedWorkspace()) {
                        sh 'mkdir -p deploy'
                        pipelineState.changedRepos = []
                        pipelineState.changedServices = []

                        for (String repo : ALL_REPOS) {
                            boolean changed = syncRepository(params.GITHUB_ORG, repo, params.BRANCH)
                            echo "${repo}: ${changed ? 'updated' : 'unchanged'}"
                            if (changed) {
                                pipelineState.changedRepos << repo
                            }
                        }

                        for (String repo : pipelineState.changedRepos) {
                            if (REPO_SERVICES.containsKey(repo)) {
                                pipelineState.changedServices.addAll(REPO_SERVICES[repo])
                            }
                        }

                        pipelineState.changedServices = pipelineState.changedServices.unique()
                        pipelineState.fullDeploy = pipelineState.changedRepos.contains('platform_infrastructure')
                        pipelineState.reposToVerify = params.VERIFY_ALL ? ALL_REPOS : pipelineState.changedRepos

                        echo "Changed repositories: ${pipelineState.changedRepos ?: 'none'}"
                        echo "Repositories to verify: ${pipelineState.reposToVerify ?: 'none'}"
                        echo "Changed services: ${pipelineState.changedServices ?: 'none'}"
                    }
                }
            }
        }

        stage('Verify') {
            when {
                expression { !pipelineState.reposToVerify.isEmpty() }
            }
            steps {
                script {
                    ws(sharedWorkspace()) {
                        for (String repo : pipelineState.reposToVerify) {
                            if (repo == 'platform_infrastructure') {
                                runInfrastructureChecks()
                            } else {
                                runRepositoryChecks(repo)
                            }
                        }
                    }
                }
            }
        }

        stage('SonarQube') {
            when {
                expression { !pipelineState.reposToVerify.isEmpty() }
            }
            steps {
                script {
                    ws(sharedWorkspace()) {
                        withSonarQubeEnv('SonarQube') {
                            for (String repo : pipelineState.reposToVerify) {
                                if (!repo.startsWith('service_')) {
                                    continue
                                }
                                String servicePath = repositoryPath(repo)
                                dir(servicePath) {
                                    withEnv(["SONAR_TOKEN=${env.SONAR_AUTH_TOKEN ?: env.SONAR_TOKEN}"]) {
                                        sh """
                                            sonar-scanner \
                                                -Dsonar.projectKey=vistay-${repo} \
                                                -Dsonar.projectName=ViStay-${repo} \
                                                -Dsonar.sources=src/main \
                                                -Dsonar.java.binaries=${servicePath}/build/classes/java/main \
                                                -Dsonar.working.directory=/tmp/sonar-work/${repo}
                                        """
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        stage('Deploy') {
            when {
                expression { params.DEPLOY_ENABLED }
            }
            steps {
                script {
                    ws(sharedWorkspace()) {
                        String infraPath = repositoryPath('platform_infrastructure')
                        ensureEnvironmentFile(infraPath)

                        boolean running = isStackRunning(infraPath)
                        boolean full = false
                        boolean buildAll = false

                        if (params.DEPLOY_MODE == 'full' || !running) {
                            full = true
                            buildAll = true
                        } else if (pipelineState.fullDeploy) {
                            full = true
                        } else if (pipelineState.changedServices.isEmpty()) {
                            echo 'No deployable service changes detected; the running stack is left unchanged.'
                            return
                        }

                        ensureCertificates(infraPath)
                        deployStack(infraPath, pipelineState.changedServices, full, buildAll, params.COMPOSE_PROFILE)
                    }
                }
            }
        }
    }

    post {
        always {
            script {
                String infraPath = repositoryPath('platform_infrastructure')
                if (fileExists("${infraPath}/.env")) {
                    dir(infraPath) {
                        sh "${composeCommand(params.COMPOSE_PROFILE)} ps || true"
                    }
                }
            }
        }
        failure {
            script {
                String infraPath = repositoryPath('platform_infrastructure')
                if (fileExists("${infraPath}/.env")) {
                    dir(infraPath) {
                        sh "${composeCommand(params.COMPOSE_PROFILE)} logs --no-color --tail=200 || true"
                    }
                }
            }
        }
    }
}

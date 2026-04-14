.PHONY: docs

# Load configuration
-include .env

# Function to strip single/double quotes using Make functions
define strip_quotes
$(subst ",,$(subst ',,$($(1))))
endef

# Disable printing directory traversal on task start/end
MAKEFLAGS += --no-print-directory

# Constants
IMAGE_VERSION ?= local
SMAPI_VERSION ?= 4.5.2
COMPOSE_FILE ?= ./docker-compose.yaml

SERVER_IMAGE_NAME ?= sdvd/server
SERVER_DOCKERFILE_PATH=./docker/Dockerfile

STEAM_SERVICE_IMAGE_NAME ?= sdvd/steam-service
STEAM_SERVICE_CONTEXT_PATH ?= ./tools/steam-service
STEAM_SERVICE_DOCKERFILE_PATH ?= ./tools/steam-service/Dockerfile

DISCORD_BOT_IMAGE_NAME ?= sdvd/discord-bot
DISCORD_BOT_CONTEXT_PATH ?= ./tools/discord-bot
DISCORD_BOT_DOCKERFILE_PATH ?= ./tools/discord-bot/Dockerfile

TEST_CLIENT_SERVER_IMAGE_NAME ?= sdvd/test-client
TEST_CLIENT_SERVER_DOCKERFILE_PATH ?= ./docker/Dockerfile.test-client

# Build configuration (Debug for local, Release for CI/production)
BUILD_CONFIGURATION ?= Debug

# Docker build progress output (plain, tty, auto, quiet)
DOCKER_PROGRESS ?= plain

# Docker cache switch
DOCKER_CACHE ?= true

# Export IMAGE_VERSION for usage in docker compose commands
export IMAGE_VERSION

# Export make variables as actual environment variables,
# so that we can pass them as docker secrets during build
STEAM_USERNAME ?=
STEAM_PASSWORD ?=
STEAM_REFRESH_TOKEN ?=

export STEAM_USERNAME := $(call strip_quotes,STEAM_USERNAME)
export STEAM_PASSWORD := $(call strip_quotes,STEAM_PASSWORD)
export STEAM_REFRESH_TOKEN := $(call strip_quotes,STEAM_REFRESH_TOKEN)

# Cross-platform ISO 8601 UTC timestamp (safe for use with filenames etc.)
ifeq ($(OS),Windows_NT)
    TIMESTAMP := $(shell powershell -NoProfile -Command "(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH-mm-ss')")Z
else
    TIMESTAMP := $(shell date -u '+%Y-%m-%dT%H-%M-%S')Z
endif

# Build docker image (downloads game during build for mod compilation)
build:
	@echo Building image 1: "$(STEAM_SERVICE_IMAGE_NAME):$(IMAGE_VERSION)"
	@docker buildx build \
                -t $(STEAM_SERVICE_IMAGE_NAME):$(IMAGE_VERSION) \
                $(if $(filter-out local,$(IMAGE_VERSION)),-t $(STEAM_SERVICE_IMAGE_NAME):latest) \
                -f $(STEAM_SERVICE_DOCKERFILE_PATH) \
                --load \
                --progress=$(DOCKER_PROGRESS) \
                $(STEAM_SERVICE_CONTEXT_PATH)
	@echo Building process of image 1 has completed.
	@echo Building image 2: "$(SERVER_IMAGE_NAME):$(IMAGE_VERSION)" with BUILD_CONFIGURATION=$(BUILD_CONFIGURATION)...
	@docker buildx build \
		--build-arg BUILD_CONFIGURATION=$(BUILD_CONFIGURATION) \
                --build-arg SMAPI_VERSION=$(SMAPI_VERSION) \
		-t $(SERVER_IMAGE_NAME):$(IMAGE_VERSION) \
		$(if $(filter-out local,$(IMAGE_VERSION)),-t $(SERVER_IMAGE_NAME):latest) \
		--secret id=steam_username,env=STEAM_USERNAME \
		--secret id=steam_password,env=STEAM_PASSWORD \
		--secret id=steam_refresh_token,env=STEAM_REFRESH_TOKEN \
		-f $(SERVER_DOCKERFILE_PATH) \
		--load \
		--progress=$(DOCKER_PROGRESS) \
		.
	@echo Building process of image 2 has completed.

build-all: build
	@echo Builing image 3: "$(DISCORD_BOT_IMAGE_NAME):$(IMAGE_VERSION)"
	@docker buildx build \
                -t $(DISCORD_BOT_IMAGE_NAME):$(IMAGE_VERSION) \
                $(if $(filter-out local,$(IMAGE_VERSION)),-t $(STEAM_SERVICE_IMAGE_NAME):latest) \
                -f $(DISCORD_BOT_DOCKERFILE_PATH) \
                --load \
                --progress=$(DOCKER_PROGRESS) \
                $(DISCORD_BOT_CONTEXT_PATH)

# Install the Docker compose
install:
	@echo Installing the Stardew Valley Dedicated Server with Docker Compose
	@docker compose -f $(COMPOSE_FILE) up -d
	@echo Docker Compose is up. See "docker ps" and "docker compose ls" or check the $(COMPOSE_FILE).

setup:
	@echo Running steam-auth setup
	@docker compose -f $(COMPOSE_FILE) run --rm -it steam-service setup
	@echo Downloaded game files and prepared a ready state

# Build test client docker image (for containerized E2E tests)
build-test-client:
	@echo Building test client image `$(TEST_CLIENT_SERVER_IMAGE_NAME):$(IMAGE_VERSION)`...
	@docker buildx build \
		--platform=linux/amd64 \
		-t $(TEST_CLIENT_SERVER_IMAGE_NAME):$(IMAGE_VERSION) \
		--secret id=steam_username,env=STEAM_USERNAME \
		--secret id=steam_password,env=STEAM_PASSWORD \
		--secret id=steam_refresh_token,env=STEAM_REFRESH_TOKEN \
		-f $(TEST_CLIENT_SERVER_DOCKERFILE_PATH) \
		--load \
		--progress=$(DOCKER_PROGRESS) \
		.
	@echo Test client build complete.

# Start docs dev server (extracts OpenAPI spec from Docker image first)
docs:
	@echo Extracting OpenAPI spec from $(SERVER_IMAGE_NAME):$(IMAGE_VERSION) image...
	@bun -e "require('fs').mkdirSync('docs/assets', { recursive: true })"
	-@bun -e "try{require('child_process').execSync('docker rm -f openapi-extract',{stdio:'ignore'})}catch(e){}"
	@docker create --name openapi-extract $(SERVER_IMAGE_NAME):$(IMAGE_VERSION)
	@docker cp openapi-extract:/data/openapi.json docs/assets/openapi.json
	@docker rm openapi-extract
	@echo OpenAPI spec ready.
	@bun --cwd=./docs run dev

# Clean up everything, including all volumes
clean:
	@echo Cleaning up...
	@docker system prune -a --force

# Run tests. Use FILTER to run specific tests:
#   make test FILTER=PasswordProtection
#   make test FILTER="Login_WithCorrectPassword"
#   make test (runs all tests)
FILTER ?=
export COLUMNS=160
test:
	@dotnet tool restore
	@dotnet test ./tests/JunimoServer.Tests/ --settings ./tests/JunimoServer.Tests/JunimoServer.Tests.runsettings $(if $(FILTER),--filter "$(FILTER)")
	@echo Generating test report...
	@dotnet TrxToExtentReport -t ./TestResults/TestResults.trx -o ./TestResults/TestReport.html

# Show help
help:
	@echo Stardew Valley Dedicated Server
	@echo ""
	@echo Targets:
	@echo "  make install  - Install development dependencies (commitlint, git hooks)"
	@echo "  make build    - Build docker image"
	@echo "  make docs     - Start docs dev server (requires built image)"
	@echo "  make clean    - Remove ALL containers, volumes and images"
	@echo "  make test     - Run E2E tests (use FILTER=X to filter, e.g. FILTER=PasswordProtection)"
	@echo "  make build-test-client - Build test client container image (for E2E tests)"
	@echo ""
	@echo Note: Use GitHub Actions for building and pushing release images

.DEFAULT_GOAL := help

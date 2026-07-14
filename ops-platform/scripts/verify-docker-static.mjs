import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const root = process.cwd();

function read(relativePath) {
  return readFileSync(resolve(root, relativePath), "utf8");
}

function fail(message) {
  throw new Error(message);
}

function assertIncludes(name, text, expected) {
  if (!text.includes(expected)) {
    fail(`${name} is missing ${expected}`);
  }
}

function assertLine(name, text, expected) {
  const lines = text.split(/\r?\n/).map((line) => line.trim());
  if (!lines.includes(expected)) {
    fail(`${name} is missing line ${expected}`);
  }
}

function section(text, heading) {
  const lines = text.split(/\r?\n/);
  const start = lines.findIndex((line) => line === `${heading}:`);
  if (start === -1) {
    return "";
  }
  const collected = [];
  for (const line of lines.slice(start + 1)) {
    if (line.length > 0 && !line.startsWith(" ")) {
      break;
    }
    collected.push(line);
  }
  return collected.join("\n");
}

function serviceBlock(compose, serviceName) {
  const lines = compose.split(/\r?\n/);
  const start = lines.findIndex((line) => line === `  ${serviceName}:`);
  if (start === -1) {
    return "";
  }
  const collected = [];
  for (const line of lines.slice(start + 1)) {
    if (line.startsWith("  ") && !line.startsWith("    ")) {
      break;
    }
    if (line.length > 0 && !line.startsWith(" ")) {
      break;
    }
    collected.push(line);
  }
  return collected.join("\n");
}

function assertService(compose, serviceName) {
  const block = serviceBlock(compose, serviceName);
  if (!block) {
    fail(`docker-compose.yml is missing service ${serviceName}`);
  }
  return block;
}

const compose = read("docker-compose.yml");
const api = assertService(compose, "api");
const web = assertService(compose, "web");
const worker = assertService(compose, "worker");
const postgres = assertService(compose, "postgres");
const redis = assertService(compose, "redis");
const volumes = section(compose, "volumes");

assertIncludes("api service", api, "dockerfile: apps/api/Dockerfile");
assertIncludes("api service", api, "env_file:");
assertIncludes("api service", api, "DATABASE_URL:");
assertIncludes("api service", api, "REDIS_URL:");
assertIncludes("api service", api, "API_PORT: 8080");
assertIncludes("api service", api, "postgres:");
assertIncludes("api service", api, "redis:");
assertIncludes("api service", api, "condition: service_healthy");
assertIncludes("api service", api, "/api/v1/health");
assertIncludes(
  "api service",
  api,
  '"${API_BIND_HOST:-127.0.0.1}:${API_PORT:-8080}:8080"'
);

assertIncludes("web service", web, "dockerfile: apps/web/Dockerfile");
assertIncludes("web service", web, "VITE_API_BASE_URL:");
assertIncludes("web service", web, "VITE_DEMO_MODE:");
assertIncludes("web service", web, "api:");
assertIncludes("web service", web, "condition: service_healthy");
assertIncludes("web service", web, "wget -qO- http://127.0.0.1/");
assertIncludes(
  "web service",
  web,
  '"${WEB_BIND_HOST:-127.0.0.1}:${WEB_PORT:-8081}:80"'
);

assertIncludes("worker service", worker, "dockerfile: apps/api/Dockerfile");
assertIncludes("worker service", worker, "command: [\"node\", \"dist/api/jobs/worker.js\"]");
assertIncludes("worker service", worker, "postgres:");
assertIncludes("worker service", worker, "redis:");
assertIncludes("worker service", worker, 'DATABASE_AUTO_MIGRATE: "false"');
assertIncludes("worker service", worker, 'DATABASE_SEED_DEFAULTS: "false"');
assertIncludes("worker service", worker, "api:");
assertIncludes("worker service", worker, "condition: service_healthy");

assertIncludes("postgres service", postgres, "image: postgres:16-alpine");
assertIncludes(
  "postgres service",
  postgres,
  "${DATA_ROOT:-./data}/postgres:/var/lib/postgresql/data"
);
assertIncludes("postgres service", postgres, "pg_isready");

assertIncludes("redis service", redis, "image: redis:7-alpine");
assertIncludes("redis service", redis, "redis-server");
assertIncludes("redis service", redis, "${DATA_ROOT:-./data}/redis:/data");

const apiDockerfile = read("apps/api/Dockerfile");
assertIncludes("apps/api/Dockerfile", apiDockerfile, "RUN npm ci");
assertIncludes("apps/api/Dockerfile", apiDockerfile, "RUN npm run build:api");
assertIncludes("apps/api/Dockerfile", apiDockerfile, "RUN npm ci --omit=dev");
assertIncludes("apps/api/Dockerfile", apiDockerfile, "CMD [\"node\", \"dist/api/server.js\"]");

const webDockerfile = read("apps/web/Dockerfile");
assertIncludes("apps/web/Dockerfile", webDockerfile, "ARG VITE_API_BASE_URL=/api/v1");
assertIncludes("apps/web/Dockerfile", webDockerfile, "ARG VITE_DEMO_MODE=false");
assertIncludes("apps/web/Dockerfile", webDockerfile, "RUN npm run build:web");
assertIncludes("apps/web/Dockerfile", webDockerfile, "FROM nginx:1.27-alpine AS runtime");
assertIncludes("apps/web/Dockerfile", webDockerfile, "COPY nginx/default.conf /etc/nginx/conf.d/default.conf");

const nginx = read("nginx/default.conf");
assertIncludes("nginx/default.conf", nginx, "location /api/");
assertIncludes("nginx/default.conf", nginx, "proxy_pass http://api:8080/api/;");
assertIncludes("nginx/default.conf", nginx, "try_files $uri $uri/ /index.html;");

const openresty = read("deploy/openresty/ops.stacio.cn.conf");
assertIncludes("deploy/openresty/ops.stacio.cn.conf", openresty, "location /updates/");
assertIncludes(
  "deploy/openresty/ops.stacio.cn.conf",
  openresty,
  "proxy_pass http://127.0.0.1:18082;"
);

const dockerignore = read(".dockerignore");
for (const line of [
  ".env",
  ".env.*",
  "!.env.example",
  ".bootstrap-credentials",
  "data",
  "node_modules",
  "dist",
  "coverage"
]) {
  assertLine(".dockerignore", dockerignore, line);
}

const envExample = read(".env.example");
for (const key of [
  "JWT_SECRET=",
  "API_BIND_HOST=",
  "WEB_BIND_HOST=",
  "BOOTSTRAP_OWNER_EMAIL=",
  "BOOTSTRAP_OWNER_PASSWORD=",
  "CONNECTOR_ENCRYPTION_KEY_BASE64=",
  "DATA_ROOT=",
  "DATABASE_URL=",
  "REDIS_URL=",
  "S3_ENDPOINT=",
  "SMTP_HOST=",
  "GITHUB_TOKEN=",
  "AGENT_API_KEYS_JSON=",
  "LICENSE_PRIVATE_KEY_BASE64="
]) {
  assertIncludes(".env.example", envExample, key);
}

const bootstrapScript = read("scripts/bootstrap-production-env.sh");
assertIncludes(
  "scripts/bootstrap-production-env.sh",
  bootstrapScript,
  "Refusing to overwrite existing environment file"
);
assertIncludes("scripts/bootstrap-production-env.sh", bootstrapScript, "openssl genpkey -algorithm Ed25519");
assertIncludes("scripts/bootstrap-production-env.sh", bootstrapScript, "CONNECTOR_ENCRYPTION_KEY_BASE64");
assertIncludes("scripts/bootstrap-production-env.sh", bootstrapScript, "AGENT_API_KEYS_JSON");
assertIncludes("scripts/bootstrap-production-env.sh", bootstrapScript, ".bootstrap-credentials");

const deployScript = read("scripts/deploy-production.sh");
assertIncludes("scripts/deploy-production.sh", deployScript, 'docker compose --env-file "$env_file"');
assertIncludes(
  "scripts/deploy-production.sh",
  deployScript,
  'if [ ! -e .env ] && [ ! -L .env ] && [ "$env_file" != ".env" ]; then'
);
assertIncludes("scripts/deploy-production.sh", deployScript, 'ln -s "$env_link" .env');
assertIncludes("scripts/deploy-production.sh", deployScript, "config --quiet");
assertIncludes("scripts/deploy-production.sh", deployScript, "up -d --build");
assertIncludes("scripts/deploy-production.sh", deployScript, "/api/v1/health");
assertIncludes("scripts/deploy-production.sh", deployScript, '"$env_file" ps');

console.log("docker-static: ok");

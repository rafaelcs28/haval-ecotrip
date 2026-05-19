FROM node:20-alpine

# Pacotes nativos opcionais (não-críticos mas evitam warnings)
RUN apk add --no-cache python3 make g++ \
 && ln -sf python3 /usr/bin/python

WORKDIR /app

# Instala deps primeiro pra aproveitar layer cache do Docker
COPY package*.json ./
RUN npm ci --omit=dev && npm cache clean --force

# Copia o resto do código
COPY . .

EXPOSE 3000 3443

# Healthcheck simples: o endpoint /ping é público
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost:3000/ping || exit 1

CMD ["node", "server.js"]

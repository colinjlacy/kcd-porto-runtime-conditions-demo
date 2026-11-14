# syntax=docker/dockerfile:1
ARG NODE_IMAGE=node:22-bookworm-slim@sha256:e9f565d32859f0cbfb52125eafe8be39390f24dac302dc3cdf566e8ba3ab21ee

FROM ${NODE_IMAGE} AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json tsconfig.build.json ./
COPY src ./src
RUN npm run build

FROM ${NODE_IMAGE} AS dependencies
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

FROM ${NODE_IMAGE}
ENV NODE_ENV=production
WORKDIR /app
COPY --from=dependencies /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY package.json ./
COPY drizzle ./drizzle
USER node
CMD ["node", "dist/main.js"]

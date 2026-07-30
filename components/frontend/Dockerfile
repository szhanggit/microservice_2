# Stage 1: build the Angular app
FROM node:20-alpine AS build
WORKDIR /app

ARG NG_APP_ENV=production
ARG GIT_SHA=unknown
ENV NG_APP_ENV=$NG_APP_ENV
ENV GIT_SHA=$GIT_SHA

COPY package*.json ./
RUN npm ci

COPY . .
RUN npm run build -- --configuration production

# Stage 2: serve the built static files with Nginx
FROM nginx:1.27-alpine

COPY --from=build /app/dist/frontend/browser /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80

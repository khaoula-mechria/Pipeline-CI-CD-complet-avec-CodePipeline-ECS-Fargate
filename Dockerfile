FROM node:20-alpine

WORKDIR /app

COPY package*.json ./
RUN npm ci

COPY task-manager ./task-manager

EXPOSE 3000

CMD ["node", "task-manager/server.js"]
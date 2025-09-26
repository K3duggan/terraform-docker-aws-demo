# Small, fast base image
FROM node:20-alpine

WORKDIR /usr/src/app

# Only copy the files we need
COPY package.json ./
COPY app.js ./

RUN npm install --production

# Use port 80 as requested
EXPOSE 80

CMD ["npm", "start"]

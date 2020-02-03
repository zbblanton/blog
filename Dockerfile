FROM nginx:alpine AS builder

RUN apk add git

RUN git clone https://github.com/zbblanton/blog.git

FROM nginx:alpine

COPY --from=builder /blog/public /usr/share/nginx/html/

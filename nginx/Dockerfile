FROM nginx:alpine
RUN apk add --no-cache netcat-openbsd
COPY wait-for-backends.sh /wait-for-backends.sh
COPY nginx.conf /etc/nginx/conf.d/default.conf
RUN chmod +x /wait-for-backends.sh
ENTRYPOINT ["/wait-for-backends.sh"]
CMD ["nginx", "-g", "daemon off;"]

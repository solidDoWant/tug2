FROM golang:1.25 AS env-runner

# This approach isn't terribly efficient but it is pretty simple

COPY . /go/src

RUN go build -C /go/src/ -o /env-runner


# node-s3-resumable-upload

This is an experiment in creating an easy to use upload server which supports resumable uploads (like on [YouTube](https://developers.google.com/youtube/2.0/developers_guide_protocol_resumable_uploads) or [Vimeo](http://developer.vimeo.com/apis/advanced/upload)) directly into S3.
Data is never saved on disc.
The motivation is to allow resilient upload, where most of the times upload will succeed, but at times, connection might drop (mainly when uploading big files or uploading on a mobile connection / 3G) and resuming the upload is crucial. Another reason that this might be important is to allow 3rd party developers who would like to integrate with your service, to start by implementing a naive upload process, and later on add the resumable layer.

Another aspect of this service is authentication: the upload service allows callback to your main application service in order to check if the user is allowed to upload the file.

## How does it work
* ChunkedStream class allows piping an input stream to be uploaded into S3 while turning it into a multipart uploads with each chunk set to ~6MB (configurable on ChunkedStream.chunkSize). If the connection is dropped, the chunks are kept on S3 and the upload may be resumed by using Content-Range headers.

## Uploading
* Start upload

```
    PUT /upload/big-filename.mp4 HTTP/1.1
    Host: upload.example.com
    Content-Type: video/mp4
    Content-Length: <content_length>

    <Binary File Data>
```

* Once an upload is interrupted (e.g: connection drop), the client should query the server which byte range was stored and where it should resume from, like this:

```
    PUT /upload/big-filename.mp4 HTTP/1.1
    Host: upload.example.com
    Content-Range: bytes */*
```

* The server will respond with a 308 status code

```
    HTTP/1.1 308
    Content-Length: 0
    Range: bytes=0-6291455
```

* Resume upload

```
    PUT /upload/big-filename.mp4 HTTP/1.1
    Host: upload.example.com
    Content-Type: video/mp4
    Content-Length: <content_length>
    Content-Range: bytes <first_byte>-<last_byte>/<total_content_length>

    <Partial Binary File Data>
```

## Dependencies
* Node v0.8.4 ( [aws2js](https://github.com/SaltwaterC/aws2js), [restler](https://github.com/danwrong/restler))
* Coffeescript

## Things to note
* This is still just an initial commit and still has a lot of tidying and cleanups to do.
* This upload service processes only binary uploads. However you should be able to easily tweak it by piping the request through a form parser (like [formidable](https://github.com/felixge/node-formidable) )
* Byte ranges are 0-based. See notes at the bottom of the [YouTube Resumable Uploads](https://developers.google.com/youtube/2.0/developers_guide_protocol_resumable_uploads)
* As for now, this was not tested in production environment.

## Pull Request and roadmap
* Code cleanups and making the service more generic is welcome
* Need to add callback to main service upon upload completion
* Retry S3 multipart merge callbacks, since S3 has consistency issues at times
* A cleanup cronjob which would clean stale uploads
* Allowing to start new uploads with Content-Range headers. Currently Content-Range headers imply resuming existing upload
* Allowing multiple threads to upload the same object ("swarm upload"). This is a big task that will require moving some of the upload persistency and information into a database.
* Supporting Google Cloud Storage API
* Measure Performance and write pricing statistics and ideal setup machine on EC2
* Optimize performance of both process CPU utilization and upload throughput

## Installation

* Clone the source
* Edit config/app.yaml with your AWS credentials, bucket name, and authentication callbacks
* Run `nodemon server.coffee`

## Open sourced by

[Boxee](http://www.boxee.tv)

## References
[YouTube API v2.0 – Resumable Uploads](https://developers.google.com/youtube/2.0/developers_guide_protocol_resumable_uploads)

[Vimeo resumable upload service](http://developer.vimeo.com/apis/advanced/upload)
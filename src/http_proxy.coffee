util            = require 'util'
_               = require('underscore')
Stream          = require "stream"
fs              = require 'fs'
zlib            = require "zlib"
http            = require "http"
https           = require "https"
url             = require "url"
connect         = require "connect"
config          = require "./config"
log             = require "./logger"
sessionFilter   = require "./session_filter"

safeParsePath = (req) ->

isSecure = (req) ->
  if req.client && req.client.pair
    true
  else if req.forceSsl
    true
  else
    false

exports.createProxy = (middlewares...) ->
  proxy = new HttpProxy(middlewares)
  return proxy

exports.HttpProxy = class HttpProxy extends connect.HTTPServer

  constructor: (middlewares) ->
    if _.isArray middlewares
      @middlewares = middlewares
    else
      @middlewares = [middlewares]
    super @bookendedMiddleware()

  bookendedMiddleware: ->
    @middlewares.unshift(@proxyCleanup)
    @middlewares.push(@outboundProxy)
    @middlewares

  proxyCleanup: (req, res, next) ->
    # Attach a namespace object to request and response for safer stashing of
    # properties and functions you'd like to have tag along
    req.mf ||= {}
    res.mf ||= {}
    # Request now has an explicit host which can be overridden later
    req.host = req.headers['host'].split(":")[0]
    req.port = req.headers['host'].split(":")[1]

    if isSecure(req)
      # Helper property
      req.href = "https://" + req.headers['host'] + req.path
      req.ssl = true
      req.port ||= 443
    else
      req.port ||= 80

      # Act as a completely transparent proxy
      # This implies that the sender is unaware of the proxy,
      # and being forced here from a network level redirect
      # Therefore the request come in as a normal path
      # Id est: '/' vs '/http://google.com'
      if config.transparent
        # Helper property
        req.href = "http://" + req.headers['host'] + req.url

      # Proxy requests send the full URL, not just the path
      # Node HTTP sees this at '/http://google.com'
      else
        safeUrl = ''
        proxyUrl = url.parse(req.url.slice(1))
        safeUrl += proxyUrl.pathname
        safeUrl += proxyUrl.search if proxyUrl.search?
        req.url = safeUrl
        req.port = proxyUrl.port
        # Helper property
        req.href = proxyUrl.href

    bodyLogger req, 'request'
    next()

  outboundProxy: (req, res, next) ->
    req.startTime = new Date
    passed_opts = {method:req.method, path:req.url, host:req.host, headers:req.headers, port:req.port}
    upstream_processor = (upstream_res) ->
      # Helpers for easier logging upstream
      res.statusCode = upstream_res.statusCode
      res.headers = upstream_res.headers

      if res.headers && res.headers['content-type'] && res.headers['content-type'].search(/(text)|(application)/) >= 0
        res.isBinary = false
      else
        res.isBinary = true

      res.emit 'headers', res.headers

      # Store body data with the response
      bodyLogger(res, 'response')

      res.writeHead(res.statusCode, res.headers)
      upstream_res.on 'data', (chunk) ->
        res.write(chunk, 'binary')
        res.emit 'data', chunk
      upstream_res.on 'end', (data)->
        res.endTime = new Date
        res.end(data)
        res.emit 'end'
      upstream_res.on 'close', ->
        res.emit 'close'
      upstream_res.on 'error', (err) ->
        log.error("Upstream Response Error - #{err}")
        res.emit 'close'
    req.on 'data', (chunk) ->
      upstream_request.write(chunk)
    req.on 'error', (error) ->
      log.error("ERROR: #{error}")
    if req.ssl
      upstream_request = https.request passed_opts, upstream_processor
    else
      upstream_request = http.request passed_opts, upstream_processor

    upstream_request.on 'error', (err)->
      log.error("Upstream Fail - #{req.method} - #{req.href}")
      dlogRequest(req, 'outboundProxy')
      log.error(err)
    upstream_request.end()

bodyLogger = (stream, type, callback) ->
  data = []
  assembleBody = ->
    stream.body = new Buffer(stream.length)
    offset = 0
    for buffer in data
      buffer.copy(stream.body, offset)
      offset += buffer.length
    data = null
  callback ||= () ->
    assembleBody()
    stream.emit 'body'
    if type == 'response'
      log.debug("Captured #{stream.body.length} bytes from #{stream.statusCode}")
  length = parseInt(stream.headers['content-length'], 10) || 0
  stream.body = new Buffer(parseInt(stream.headers['content-length'], 10))
  stream.length = 0
  unzipper = zlib.createUnzip()
  unzipper.on 'data', (datum) ->
    data.push(datum)
    stream.length += datum.length
  unzipper.on 'end', ->
    callback()
  unzipper.destroy = ->
    console.log stream.href
    console.log stream.headers
  switch (stream.headers['content-encoding'])
    when 'gzip'
      log.debug("Unzipping")
      stream.pipe(unzipper)
      break
    when 'deflate'
      log.debug("Deflating")
      stream.pipe(unzipper)
      break
    else
      stream.on 'data', (datum)->
        data.push datum
        stream.length += datum.length
      stream.on 'end', ->
        callback()
      break

dlogRequest = (req, caller) ->
  if isSecure(req)
    log.info("http_proxy.#{caller}:\n  proto: https")
  else
    log.info("http_proxy.#{caller}:\n  proto: http")
  log.info("  req.method: #{req.method}")
  log.info("  req.host: #{req.headers['host']}")
  log.info("  req.url: #{req.url}")
  if req.headers['host']
    log.info("  req.host: #{req.headers['host'].split(':')[0]}")
    log.info("  req.port: #{req.headers['host'].split(':')[1]}")

  log.info("  req.path: #{req.path}")
  log.info("  req.href: #{req.href}")
  log.error("-----------")



ipc = require 'ipc'
https = require 'https'
querystring = require 'querystring'
{EventEmitter} = require 'events'

module.exports =
class LearnNotificationManager extends EventEmitter
  constructor: (authToken) ->
    @authToken     = authToken
    @notifRegistry = []
    @connection = null

  authenticate: =>
    return new Promise (resolve, reject) =>
      https.get
        host: 'learn.co'
        path: '/api/v1/users/me'
        headers:
          'Authorization': 'Bearer ' + @authToken
      , (response) =>
        body = ''

        response.on 'data', (d) ->
          body += d

        response.on 'error', ->
          reject Error('Cannot subscribe to notifications. Problem parsing response.')

        response.on 'end', =>
          try
            parsed = JSON.parse(body)

            if parsed.id
              @id = parsed.id

              resolve this
            else
              reject Error('Cannot subscribe to notifications. Not authorized.')
          catch
            reject Error('Cannot subscribe to notifications. Problem parsing response.')

  subscribe: =>
    console.log @id
    true
    #@connection = new WebSocket('wss://push.flatironschool.com:9443/ws/fis-user-' + @id)

    #@connection.onopen = (e) =>
      #this.emit 'notification-debug', 'Listening for notifications...'

    #@connection.onmessage = (e) =>
      #try
        #rawData = JSON.parse(e.data)
        #eventData = querystring.parse rawData.text

        #this.emit 'notification-debug', eventData
      #catch
        #this.emit 'notification-debug', 'Error creating notification.'

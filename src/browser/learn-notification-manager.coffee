ipc = require 'ipc'
https = require 'https'
querystring = require 'querystring'
{EventEmitter} = require 'events'
WebSocket = require('websocket').w3cwebsocket

module.exports =
class LearnNotificationManager extends EventEmitter
  constructor: (authToken) ->
    @authToken     = authToken
    @notifRegistry = []
    @notifTitles = {}
    @notificationTypes = ['submission']

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
    @connection = new WebSocket('wss://push.flatironschool.com:9443/ws/fis-user-' + @id)

    @connection.onopen = (e) =>
      this.emit 'notification-debug', 'Listening for notifications...'

    @connection.onmessage = (e) =>
      try
        rawData = JSON.parse(e.data)
        eventData = querystring.parse rawData.text
        uid = @eventUid eventData

        if @notificationTypes.indexOf(eventData.type) >= 0 && !(@notifRegistry.indexOf(uid) >= 0)
          @notifRegistry.push(uid)

          @getDisplayTitle(eventData).then (title) =>
            eventData.displayTitle = title
            this.emit 'new-notification', eventData
      catch err
        console.log err
        this.emit 'notification-debug', 'Error creating notification.'

  getDisplayTitle: (event) =>
    # NOTE THAT FOR NOW THIS ONLY WORKS WITH LESSONS
    return new Promise (resolve, reject) =>
      try
        displayTitle = @notifTitles[event.lesson_id]

        if displayTitle
          resolve displayTitle
        else
          https.get
            host: 'learn.co'
            path: '/api/v1/lessons/' + event.lesson_id
          , (response) =>
            body = ''

            response.on 'data', (d) ->
              body += d

            response.on 'error', ->
              @notifTitles[event.lesson_id] = 'Learn IDE'
              resolve 'Learn IDE'

            response.on 'end', =>
              try
                parsed = JSON.parse(body)

                if parsed.title
                  @notifTitles[event.lesson_id] = parsed.title
                  resolve parsed.title
                else
                  @notifTitles[event.lesson_id] = 'Learn IDE'
                  resolve 'Learn IDE'
              catch
                @notifTitles[event.lesson_id] = 'Learn IDE'
                resolve 'Learn IDE'
      catch err
        console.log err

  eventUid: (event) =>
    switch event.type
      when 'submission' then parseInt(event.submission_id)
      else null

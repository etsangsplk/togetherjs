# Abstraction over raw net stream, for use by a client.

OpStream = window?.whatnot.OpStream || require('./opstream').OpStream
types = window?.whatnot.types || require('../types')

exports ||= {}

p = -> #require('util').debug
i = -> #require('util').inspect

class Document
	# stream is a OpStream object.
	# name is the documents' docName.
	# version is the version of the document _on the server_
	constructor: (@stream, @name, @version, @type, @snapshot) ->
		throw new Error('Handling types without compose() defined is not currently implemented') unless @type.compose?

		# The op that is currently roundtripping to the server, or null.
		@inflightOp = null
		@inflightCallbacks = []

		# All ops that are waiting for the server to acknowledge @inflightOp
		@pendingOp = null
		@pendingCallbacks = []

		# Some recent ops, incase submitOp is called with an old op version number.
		@serverOps = {}

		# Listeners for the document changing
		@listeners = []

		@stream.follow @name, @version, (msg) =>
			throw new Error("Expected version #{@version} but got #{msg.v}") unless msg.v == @version
			@stream.on @name, 'op', @onOpReceived

	# Internal - do not call directly.
	tryFlushPendingOp: =>
		if @inflightOp == null && @pendingOp != null
			# Rotate null -> pending -> inflight, 
			@inflightOp = @pendingOp
			@inflightCallbacks = @pendingCallbacks

			@pendingOp = null
			@pendingCallbacks = []

			@stream.submit @name, @inflightOp, @version, (response) =>
				if response.v == null
					# Currently, it should be impossible to reach this case.
					# This case is currently untested.
					callback(null) for callback in @inflightCallbacks
					@inflightOp = null
					# Perhaps the op should be removed from the local document...
					# @snapshot = @type.apply @snapshot, type.invert(@inflightOp) if type.invert?
					throw new Error(response.error)

				throw new Error('Invalid version from server') unless response.v == @version

				@serverOps[@version] = @inflightOp
				@version++
				callback(@inflightOp, null) for callback in @inflightCallbacks
#				console.log 'Heard back from server.', this, response, @version

				@inflightOp = null
				@tryFlushPendingOp()

	# Internal - do not call directly.
	# Called when an op is received from the server.
	onOpReceived: (msg) =>
		# msg is {doc:, op:, v:}
		throw new Error("Expected docName #{@name} but got #{msg.doc}") unless msg.doc == @name
		throw new Error("Expected version #{@version} but got #{msg.v}") unless msg.v == @version

#		p "if: #{i @inflightOp} pending: #{i @pendingOp} doc '#{@snapshot}' op: #{i msg.op}"

		op = msg.op
		@serverOps[@version] = op

		# Transform a server op by a client op, and vice versa.
		xf = @type.transformX or (server, client) =>
			server_ = @type.transform server, client, 'server'
			client_ = @type.transform client, server, 'client'
			return [server_, client_]

		docOp = op
		if @inflightOp != null
			[docOp, @inflightOp] = xf docOp, @inflightOp
		if @pendingOp != null
			[docOp, @pendingOp] = xf docOp, @pendingOp
			
		@snapshot = @type.apply @snapshot, docOp
		@version++

		listener(docOp) for listener in @listeners

	# Submit an op to the server. The op maybe held for a little while before being sent, as only one
	# op can be inflight at any time.
	submitOp: (op, v = @version, callback) ->
		if typeof v == 'function'
			callback = v
			v = @version

		op = @type.normalize(op) if @type?.normalize?

		while v < @version
			realOp = @recentOps[v]
			throw new Error 'Op version too old' unless realOp
			op = @type.transform(op, realOp, 'client')
			v++

		# If this throws an exception, no changes should have been made to the doc
		@snapshot = @type.apply @snapshot, op

		if @pendingOp != null
			@pendingOp = @type.compose(@pendingOp, op)
		else
			@pendingOp = op

		@pendingCallbacks.push callback if callback?

		# A timeout is used so if the user sends multiple ops at the same time, they'll be composed
		# together and sent together.
		setTimeout @tryFlushPendingOp, 0

	# Add an event listener to listen for remote ops. Listener will be passed one parameter;
	# the op.
	onChanged: (listener) ->
		@listeners.push(listener)



class Connection
	makeDoc: (name, version, type, snapshot) ->
		throw new Error("Document #{name} already followed") if @docs[name]
		@docs[name] = new Document(@stream, name, version, type, snapshot)

	constructor: (hostname, port, basePath) ->
		@stream = new OpStream(hostname, port, basePath)
		@docs = {}

	# callback is passed a Document or null
	# callback(doc)
	get: (docName, callback) ->
		return @docs[docName] if @docs[docName]?

		@stream.get docName, (response) =>
			if response.snapshot == null
				callback(null)
			else
				type = types[response.type]
				callback @makeDoc(response.doc, response.v, type, response.snapshot)

	# Callback is passed a document or an error
	# type is either a type name (eg 'text' or 'simple') or the actual type object.
	# Types must be supported by the server.
	# callback(doc, error)
	getOrCreate: (docName, type, callback) ->
		if typeof type == 'function'
			callback = type
			type = 'text'

		type = types[type] if typeof type == 'string'

		if @docs[docName]?
			doc = @docs[docName]
			if doc.type == type
				callback(doc)
			else
				callback(doc, 'Document already exists with type ' + doc.type.name)

			return

		@stream.get docName, (response) =>
			if response.snapshot == null
				@stream.submit docName, {type: type.name}, 0, (response) =>
					if response.v?
						callback @makeDoc(docName, 1, type, type.initialVersion())
					else if response.v == null and response.error == 'Type already set'
						# Somebody else has created the document. Get the snapshot again..
						@getOrCreate(docName, type, callback)
					else
						callback(null, response.error)
			else if response.type == type.name
				callback @makeDoc(docName, response.v, type, response.snapshot)
			else
				callback null, "Document already exists with type #{response.type}"

	disconnect: () ->
		if @stream?
			@stream.disconnect()
			@stream = null

if window?
	window.whatnot.Connection = Connection
else
	exports.Connection = Connection

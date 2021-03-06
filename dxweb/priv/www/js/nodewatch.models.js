//
// Erlang System Monitoring Dashboard: Backbone Application Module
//
// Copyright (c) 2008-2010 Tim Watson (watson.timothy@gmail.com)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//

// *static* façade for service calls
Service = {
    debuggerTag: 'Service',
    loadFragment: function(path, dest) {
        return this.get({url: path,
                         accept: 'application/html',
                         dataType: 'html'})
                   .success(function(html) { dest.html(html); });
    },

    get: function(opts) {
        if (typeof(opts) == "string") {
            return this.http({ url: opts });
        } else {
            console.debug('opts:');
            console.debug(opts);
            return this.http(opts);
        }
    },

    postForm: function(url, data) {
        return $.ajax({
            async: false,
            url: url,
            type: 'POST',
            data: data
        });
    },

    http: function(opts) {
        return $.ajax(
            _.defaults(opts, {
                async: true,
                type: 'GET',
                contentType: 'application/json',
                crossDomain: true,
                processData: false,
                dataType: 'json',
            }));
    }
};

Subscription = Backbone.Model.extend({
    debuggerTag: 'Subscription',
    defaults: {
        id: 'user.node.sensor',
        user: 'user',
        node: 'nonode@nohost',
        sensor: 'none',
        mode: 'instrument'
    },
    parse: function(response) {
        var data = response.subscription;
        data.id = _.template('${user}-${node}-${sensor}', data);
        return data;
    }
});

SubscriptionList = Backbone.Collection.extend({
    debuggerTag: 'SubscriptionList',
    model: Subscription,
    initialize: function(models, opts) {
        this.url = opts.url;
    },
    parse: function(response) {
        return _.map(response,
            function(s) { return s.subscription; });
    }
});

//$('#loading').dialog({ autoOpen: false });
Node = Backbone.Model.extend({
    debuggerTag: 'Node',
    // id is the -name of the node, e.g. Node[foo@bar] => id = foo
    defaults: {
        id: 'nonode@nohost',
        status: 'unknown',
        info: []
    },
    parse: function(response) {
        return response.node_info;
    }
});

NodeSet = Backbone.Collection.extend({
    debuggerTag: 'NodeSet',
    url: '/service/nodes',
    model: Node,
    parse: function(response) {
        return _.map(response,
            function(ni) { return ni.node_info; });
    }
});

SystemStatus = Backbone.Model.extend({});

SystemStats = Backbone.Collection.extend({
    debuggerTag: 'SystemStats',
    /* NO URL! */
    model: SystemStatus,
    initialize: function(args, opts) {
        _.bindAll(this, 'destroy', 'handleSysEvent', 'render');
        this.node = opts.node;
        var eventKey = 'event:system:' + this.node;
        console.debug('subscribing to ' + eventKey);
        _application.bind(eventKey, this.handleSysEvent);
    },
    handleSysEvent: function(eventData) {
        console.debug('adding eventData');
        this.add(eventData);
    },
    destroy: function() {
        _application.unbind('event:system:' + this.node);
    }
});

// TODO: use backbone's Model#refresh to do all this.....

Session = Backbone.Model.extend({
    debuggerTag: 'Session',
    defaults: {
        version: '0.0.1',
        host: document.location.host,
        serviceUrl: 'service',
        connected: false,
        sessionId: ''
    },

    websocketUrl: function() {
        return 'ws://' +
                this.get('host') + '/'
                + this.get('sessionId');
    },

    login: function() {
        // TODO: make this synchronous or face annoying bugs later on....
        var jqXHR = Service.postForm('/service/login', this.toJSON());
        if (jqXHR.status != 200) {
            this.set({connected: false});
            return false;
        } else {
            // FIXME: this is totally broken since we moved it around...
            if ($ === undefined) return false;
            this.set({sessionId: $.cookie("sid")});
            console.debug(_.template('connecting to ${ws}',
                            {ws: this.websocketUrl()}));
            //$.cookie("nodewatch.user", this.get('username'));
            var username = this.get('username');
            if (username != undefined) {
                $.cookie('nodewatch.user', username, {
                    expires: 7,
                    path: '/',
                    domain: document.domain,
                    secure: false
                });
            }
            this.websocketConnect();
            return true;
        }
    },

    hasCookie: function() {
        return $.cookie('sid') != null;
    },

    websocketConnect: function() {
        var ws = new WebSocket(this.websocketUrl());
        var self = this;
        ws.onopen = function() {
            self.set({connected: true});
        };
        ws.onmessage = function (evt) {
            self.trigger("websock:data", evt);
        }
        ws.onclose = function() {
            self.set({connected: false});
        }
        this.set({websocket: ws});
        return this;
    },

    toJSON: function() {
        return {
            username: this.get('username'),
            password: this.get('password'),
        };
    }
});

App = Backbone.Model.extend({
    debuggerTag: 'App',
    defaults: {
        session: new Session(),
        nodes: new NodeSet([]),
        subscriptionStatus: 'off',
        subscriptions: new SubscriptionList([])
    },
    initialize: function() {
        var session = this.get('session');
        if (session != undefined) {
            var self = this;
            session.bind("websock:data", function(msg) {
                self.publishEvent(msg);
            });
        }
    },
    publishEvent: function(msg) {
        var ev = JSON.parse(msg.data).event;
        if (ev.tag == 'system') {
            var info = ev.data[1];
            var key = 'event:system:' + info.node;
            console.debug('publishing ' + key);
            this.trigger(key, info);
        } else if (ev.tag == 'process') {
            var obj = ev.data[1];
            var key = "event:process:" + obj.node;
            console.debug('publishing ' + key);
            this.trigger(key, obj);
        } else {
            this.trigger('event:' + ev.tag, ev.data);
        }
    },
    activateSubscriptions: function() {
        this.toggleSubscriptions('PUT', 'ON');
    },
    deactivateSubscriptions: function() {
        this.toggleSubscriptions('DELETE', 'OFF');
    },
    toggleSubscriptions: function(method, status) {
        var session = this.get('session');
        var uname = session.get('username');
        $.ajax({
            url: '/service/subscriptions/active/' + uname,
            type: method,
            data: "",
            context: this
        }).success(function() { this.set({subscriptionStatus: status}); })
          .error(function() { console.debug('Unable to modify event feed!'); });
    }
});


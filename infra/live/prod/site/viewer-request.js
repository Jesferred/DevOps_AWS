// CloudFront Function (cloudfront-js-2.0), viewer-request.
// 1. www.kovalov.in -> https://kovalov.in (301, path and query preserved)
// 2. /blog/post and /blog/post/ -> /blog/post/index.html (Astro directory output)

var APEX = 'kovalov.in';

function querystring(qs) {
  var parts = [];
  for (var key in qs) {
    var v = qs[key];
    if (v.multiValue) {
      for (var i = 0; i < v.multiValue.length; i++) {
        parts.push(key + '=' + v.multiValue[i].value);
      }
    } else {
      parts.push(key + '=' + v.value);
    }
  }
  return parts.length ? '?' + parts.join('&') : '';
}

function handler(event) {
  var request = event.request;
  var host = request.headers.host ? request.headers.host.value : '';

  if (host !== APEX) {
    return {
      statusCode: 301,
      statusDescription: 'Moved Permanently',
      headers: {
        location: { value: 'https://' + APEX + request.uri + querystring(request.querystring) },
      },
    };
  }

  var uri = request.uri;
  if (uri.endsWith('/')) {
    request.uri = uri + 'index.html';
  } else if (uri.lastIndexOf('.') < uri.lastIndexOf('/') + 1) {
    request.uri = uri + '/index.html';
  }

  return request;
}

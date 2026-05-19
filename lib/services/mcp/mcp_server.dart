import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';

import '../../data/repositories/base_repository.dart';
import '../system/logger_service.dart';
import 'mcp_tools.dart';

class MCPRequest {
  final String id;
  final String method;
  final Map<String, dynamic>? params;

  MCPRequest({required this.id, required this.method, this.params});
}

class MCPServer {
  HttpServer? _server;
  BaseRepository? _repo;
  final List<_SSEClient> _clients = [];

  bool get isRunning => _server != null;
  int get port => _server?.port ?? 0;

  Future<void> start({required BaseRepository repo, int port = 9876}) async {
    if (_server != null) return;
    _repo = repo;

    final handler = Pipeline()
        .addMiddleware(logRequests())
        .addHandler(_router);

    _server = await serve(handler, InternetAddress.loopbackIPv4, port);
    logger.info('MCP', 'MCP 服务器已启动: http://127.0.0.1:${_server!.port}');
  }

  Future<void> stop() async {
    for (final client in _clients) {
      await client.close();
    }
    _clients.clear();
    await _server?.close(force: true);
    _server = null;
    logger.info('MCP', 'MCP 服务器已停止');
  }

  FutureOr<Response> _router(Request request) {
    final uri = request.url;
    final path = uri.path;

    if (path == '/health') {
      return Response.ok(
        jsonEncode({"status": "ok", "port": port}),
        headers: {'content-type': 'application/json'},
      );
    }

    if (path == '/sse') {
      return _handleSSE(request);
    }

    if (path == '/messages' && request.method == 'POST') {
      return _handleMessage(request);
    }

    if (path == '/tools' && request.method == 'GET') {
      return _handleToolsList(request);
    }

    return Response.notFound('Not Found');
  }

  Response _handleSSE(Request request) {
    late final StreamController<String> responseStream;
    responseStream = StreamController<String>(onCancel: () {
      final client = _clients.where((c) => c.stream == responseStream).firstOrNull;
      if (client != null) {
        _clients.remove(client);
        client.close();
      }
    });

    final client = _SSEClient(responseStream);
    _clients.add(client);

    responseStream.add('event: endpoint\ndata: /messages\n\n');
    responseStream.add('event: initialized\ndata: {}\n\n');

    return Response.ok(
      responseStream.stream,
      headers: {
        'content-type': 'text/event-stream',
        'cache-control': 'no-cache',
        'connection': 'keep-alive',
        'access-control-allow-origin': '*',
      },
    );
  }

  Future<Response> _handleMessage(Request request) async {
    try {
      final body = await request.readAsString();
      final json = jsonDecode(body) as Map<String, dynamic>;

      final method = json['method'] as String?;
      final id = json['id'];
      final params = json['params'] as Map<String, dynamic>?;

      if (method == 'initialize') {
        return _jsonRpcResponse(id, {
          "protocolVersion": "2024-11-05",
          "serverInfo": {
            "name": "BeeCount MCP Server",
            "version": "1.0.0"
          },
          "capabilities": {
            "tools": {}
          }
        });
      }

      if (method == 'tools/list') {
        final tools = getToolDefinitions();
        return _jsonRpcResponse(id, tools);
      }

      if (method == 'tools/call') {
        final toolName = params?['name'] as String?;
        final arguments = params?['arguments'] as Map<String, dynamic>? ?? {};

        if (toolName == null) {
          return _jsonRpcError(id, -32602, '缺少工具名称');
        }

        final result = await handleToolCall(toolName, arguments, _repo!);
        return _jsonRpcResponse(id, {"content": [
          {"type": "text", "text": jsonEncode(result)}
        ]});
      }

      if (method == 'notifications/initialized') {
        return Response.ok('', headers: {'access-control-allow-origin': '*'});
      }

      return _jsonRpcError(id, -32601, '不支持的方法: $method');
    } catch (e) {
      return _jsonRpcError(null, -32603, '内部错误: $e');
    }
  }

  Response _handleToolsList(Request request) {
    return Response.ok(
      jsonEncode(getToolDefinitions()),
      headers: {'content-type': 'application/json', 'access-control-allow-origin': '*'},
    );
  }

  Response _jsonRpcResponse(dynamic id, Map<String, dynamic> result) {
    return Response.ok(
      jsonEncode({
        "jsonrpc": "2.0",
        "id": id,
        "result": result,
      }),
      headers: {'content-type': 'application/json', 'access-control-allow-origin': '*'},
    );
  }

  Response _jsonRpcError(dynamic id, int code, String message) {
    return Response.ok(
      jsonEncode({
        "jsonrpc": "2.0",
        "id": id,
        "error": {"code": code, "message": message},
      }),
      headers: {'content-type': 'application/json', 'access-control-allow-origin': '*'},
    );
  }
}

class _SSEClient {
  final StreamController<String> stream;
  bool _closed = false;

  _SSEClient(this.stream);

  Future<void> send(String event, String data) async {
    if (_closed) return;
    stream.add('event: $event\ndata: $data\n\n');
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await stream.close();
  }
}

/// Параметр запуска отделён от URL-пути приложения и сохраняется через логин.
class BotDeepLink {
  final String username;
  final String parameter;
  final bool opensApp;

  const BotDeepLink(
    this.username, {
    this.parameter = '',
    this.opensApp = false,
  });

  String get route => Uri(
    path: '/b/$username',
    queryParameters: opensApp
        ? {'startapp': parameter}
        : parameter.isEmpty
        ? null
        : {'start': parameter},
  ).toString();
}

BotDeepLink? parseWebBotLink(Uri uri) {
  if (uri.pathSegments.length != 2 || uri.pathSegments.first != 'b') {
    return null;
  }
  return _parseBotTarget(uri.pathSegments[1], uri);
}

BotDeepLink? parseBotLink(Uri uri) {
  if (uri.scheme == 'liza' &&
      uri.host == 'bot' &&
      uri.pathSegments.length == 1) {
    return _parseBotTarget(uri.pathSegments.single, uri);
  }
  if ((uri.scheme == 'https' || uri.scheme == 'http') &&
      const {
        'me.liza.ru',
        'dev.me.liza.ru',
        'liza.laba.pro',
      }.contains(uri.host)) {
    return parseWebBotLink(uri);
  }
  return null;
}

BotDeepLink? _parseBotTarget(String username, Uri uri) {
  if (!RegExp(r'^[A-Za-z0-9_]{1,64}$').hasMatch(username)) return null;
  final params = uri.queryParametersAll;
  if (params.containsKey('startgroup') ||
      (params.containsKey('start') && params.containsKey('startapp'))) {
    return null;
  }
  final opensApp = params.containsKey('startapp');
  final values = params[opensApp ? 'startapp' : 'start'];
  if (values != null && values.length != 1) return null;
  final parameter = values?.single ?? '';
  final limit = opensApp ? 512 : 64;
  if (parameter.length > limit ||
      (parameter.isNotEmpty &&
          !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(parameter))) {
    return null;
  }
  return BotDeepLink(username, parameter: parameter, opensApp: opensApp);
}

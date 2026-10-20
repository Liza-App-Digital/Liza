import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';

import 'package:http/http.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/account_delete_service.dart';
import 'package:liza/utils/auth_diagnostics.dart';
import 'package:liza/utils/auth_proxy_service.dart';
import 'package:liza/utils/matrix_sdk_extensions/event_extension.dart';
import 'package:liza/utils/other_party_can_receive.dart';
import 'package:liza/utils/upload_error_classifier.dart';
import 'uia_request_manager.dart';

extension LocalizedExceptionExtension on Object {
  static String _formatFileSize(int size) {
    if (size < 1000) return '$size B';
    final i = (log(size) / log(1000)).floor();
    final num = (size / pow(1000, i));
    final round = num.round();
    final numString = round < 10
        ? num.toStringAsFixed(2)
        : round < 100
        ? num.toStringAsFixed(1)
        : round.toString();
    return '$numString ${'kMGTPEZY'[i - 1]}B';
  }

  String toLocalizedString(
    BuildContext context, [
    ExceptionContext? exceptionContext,
  ]) {
    if (this is AccountDeleteException) {
      return (this as AccountDeleteException).failure ==
              AccountDeleteFailure.companyOwner
          ? L10n.of(context).deleteAccountTransferOwnership
          : L10n.of(context).deleteAccountFailed;
    }
    if (this is MediaDownloadException) {
      return L10n.of(context).couldNotLoadMedia;
    }
    if (this is FileTooBigMatrixException) {
      final exception = this as FileTooBigMatrixException;
      return L10n.of(
        context,
      ).fileIsTooBigForServer(_formatFileSize(exception.maxFileSize));
    }
    if (this is EmptyMediaBytesException) {
      return L10n.of(context).couldNotReadFileTooLargeForBrowser;
    }
    if (this is OtherPartyCanNotReceiveMessages) {
      return L10n.of(context).otherPartyNotLoggedIn;
    }
    if (this is MatrixException) {
      switch ((this as MatrixException).error) {
        case MatrixError.M_FORBIDDEN:
          if (exceptionContext == ExceptionContext.changePassword) {
            return L10n.of(context).passwordIsWrong;
          }
          return L10n.of(context).noPermission;
        case MatrixError.M_LIMIT_EXCEEDED:
          return L10n.of(context).tooManyRequestsWarning;
        default:
          if (exceptionContext == ExceptionContext.joinRoom) {
            return L10n.of(context).unableToJoinChat;
          }
          return (this as MatrixException).errorMessage;
      }
    }
    if (this is InvalidPassphraseException) {
      return L10n.of(context).wrongRecoveryKey;
    }
    if (this is BadServerLoginTypesException) {
      final serverVersions = (this as BadServerLoginTypesException)
          .serverLoginTypes
          .toString()
          .replaceAll('{', '"')
          .replaceAll('}', '"');
      final supportedVersions = (this as BadServerLoginTypesException)
          .supportedLoginTypes
          .toString()
          .replaceAll('{', '"')
          .replaceAll('}', '"');
      return L10n.of(context).badServerLoginTypesException(
        serverVersions,
        supportedVersions,
        supportedVersions,
      );
    }
    if (this is ConnectivityCheckException) {
      final cce = this as ConnectivityCheckException;
      switch (cce.failureType) {
        case ConnectivityFailureType.dns:
          return L10n.of(context).dnsResolutionFailed;
        case ConnectivityFailureType.tls:
          return L10n.of(context).tlsConnectionFailed;
        case ConnectivityFailureType.timeout:
          return L10n.of(context).connectionTimedOut;
        default:
          return L10n.of(context).connectivityCheckFailed(
            cce.host,
            cce.reason,
          );
      }
    }
    if (this is SocketException) {
      final se = this as SocketException;
      final host = se.address?.host;
      if (host != null) {
        return L10n.of(context).connectionFailedToHost(
          host,
          se.osError?.message ?? se.message,
        );
      }
      return L10n.of(context).noConnectionToTheServer;
    }
    if (this is TlsException || this is HandshakeException) {
      return L10n.of(context).tlsConnectionFailed;
    }
    if (this is TimeoutException) {
      return L10n.of(context).connectionTimedOut;
    }
    if (this is ClientException) {
      final ce = this as ClientException;
      final uri = ce.uri;
      if (uri != null) {
        return L10n.of(context).connectionFailedToHost(
          uri.host,
          ce.message,
        );
      }
      return L10n.of(context).noConnectionToTheServer;
    }
    // ДО общего IOException: FileSystemException is IOException, иначе
    // диск-переполнение (ENOSPC при чтении/шифровании байтов) лживо
    // показывалось бы как «нет соединения с сервером» (Дыра 3).
    if (this is FileSystemException) {
      return L10n.of(context).notEnoughStorageSpace;
    }
    if (this is IOException || this is SyncConnectionException) {
      return L10n.of(context).noConnectionToTheServer;
    }
    if (this is FormatException &&
        exceptionContext == ExceptionContext.checkHomeserver) {
      return L10n.of(context).doesNotSeemToBeAValidHomeserver;
    }
    if (this is FormatException &&
        exceptionContext == ExceptionContext.checkServerSupportInfo) {
      return L10n.of(context).noContactInformationProvided;
    }
    if (this is AuthProxyServerException) {
      return L10n.of(context).authServerError;
    }
    if (this is AuthProxyException) {
      final authException = this as AuthProxyException;
      return authException.serverError ?? authException.message;
    }
    if (this is String) return toString();
    if (this is UiaException) return toString();

    if (exceptionContext == ExceptionContext.joinRoom) {
      return L10n.of(context).unableToJoinChat;
    }

    Logs().w('Something went wrong: ', this);
    return L10n.of(context).oopsSomethingWentWrong;
  }
}

enum ExceptionContext {
  changePassword,
  checkHomeserver,
  checkServerSupportInfo,
  joinRoom,
}

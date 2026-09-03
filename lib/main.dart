Future<void> _startUdpDiscovery() async {
    try {
      // 绑定通配地址并允许地址重用
      _udpSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _udpPort,
        reuseAddress: true,
        reusePort: false,
      );
      _udpSocket?.broadcastEnabled = true;

      _udpSocket?.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = _udpSocket?.receive();
          if (datagram == null) return;

          try {
            final message = utf8.decode(datagram.data);
            final parts = message.split('|');
            if (parts.length >= 3 && parts[0] == 'P2P_DISCOVER') {
              final remoteDeviceName = parts[1];
              final remoteOs = parts[2];
              final remoteIp = datagram.address.address;

              // 过滤本机自身
              if (!_localIps.contains(remoteIp) && remoteIp != '127.0.0.1') {
                setState(() {
                  _devices[remoteIp] = DiscoveredDevice(
                    ip: remoteIp,
                    name: remoteDeviceName,
                    os: remoteOs,
                    lastSeen: DateTime.now(),
                  );
                });
              }
            }
          } catch (_) {}
        }
      });

      // 每 2 秒全网段广播，并针对子网广播一次
      _broadcastTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
        if (_udpSocket == null || _localIps.isEmpty) return;
        final packet = 'P2P_DISCOVER|$_deviceName|${Platform.operatingSystem}';
        final data = utf8.encode(packet);

        // 1. 全局广播
        try {
          _udpSocket?.send(data, InternetAddress('255.255.255.255'), _udpPort);
        } catch (_) {}

        // 2. 针对当前网段的定向广播 (如 192.168.1.255)
        for (final ip in _localIps) {
          final segments = ip.split('.');
          if (segments.length == 4) {
            final subnetBroadcast = '${segments[0]}.${segments[1]}.${segments[2]}.255';
            try {
              _udpSocket?.send(data, InternetAddress(subnetBroadcast), _udpPort);
            } catch (_) {}
          }
        }
      });

      _cleanupTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
        final now = DateTime.now();
        setState(() {
          _devices.removeWhere(
              (_, device) => now.difference(device.lastSeen).inSeconds > 6);
        });
      });
    } catch (e) {
      setState(() => _status = 'UDP 启动异常: $e');
    }
  }

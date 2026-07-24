import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'controllers/grill_controller.dart';
import 'protocol/grill_protocol.dart';

void main() => runApp(const SmarterGrillApp());

class SmarterGrillApp extends StatelessWidget {
  const SmarterGrillApp({super.key});

  @override
  Widget build(BuildContext context) {
    const ember = Color(0xffc54b2c);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Smarter Grill',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: ember,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xfff6f3ed),
        cardTheme: const CardThemeData(elevation: 0, margin: EdgeInsets.zero),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
        useMaterial3: true,
      ),
      home: const GrillDashboard(),
    );
  }
}

class GrillDashboard extends StatefulWidget {
  const GrillDashboard({super.key});

  @override
  State<GrillDashboard> createState() => _GrillDashboardState();
}

class _GrillDashboardState extends State<GrillDashboard> {
  late final GrillController controller;

  @override
  void initState() {
    super.initState();
    controller = GrillController()..addListener(_changed);
    controller.initialize();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    controller.removeListener(_changed);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverAppBar.large(
              backgroundColor: Theme.of(context).scaffoldBackgroundColor,
              title: const Text('Smarter Grill'),
              actions: [
                _ConnectionBadge(phase: controller.phase),
                const SizedBox(width: 16),
              ],
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 40),
              sliver: SliverList.list(
                children: [
                  if (controller.phase == GrillConnectionPhase.needsId)
                    _SetupCard(controller: controller),
                  _PowerCard(controller: controller),
                  const SizedBox(height: 16),
                  _GrillTemperatureCard(controller: controller),
                  const SizedBox(height: 16),
                  Text(
                    'Food probes',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 10),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final width = constraints.maxWidth > 650
                          ? (constraints.maxWidth - 12) / 2
                          : constraints.maxWidth;
                      return Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          for (var i = 0; i < 3; i++)
                            SizedBox(
                              width: width,
                              child: _ProbeCard(
                                controller: controller,
                                index: i,
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                  _AdvancedCard(controller: controller),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionBadge extends StatelessWidget {
  const _ConnectionBadge({required this.phase});
  final GrillConnectionPhase phase;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (phase) {
      GrillConnectionPhase.connected => ('ONLINE', const Color(0xff2e7d5b)),
      GrillConnectionPhase.connecting => (
        'CONNECTING',
        const Color(0xffb26a00),
      ),
      GrillConnectionPhase.error => (
        'ERROR',
        Theme.of(context).colorScheme.error,
      ),
      GrillConnectionPhase.needsId => ('SETUP', const Color(0xff6d6257)),
      GrillConnectionPhase.disconnected => ('OFFLINE', const Color(0xff6d6257)),
    };
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(30),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.circle, color: color, size: 9),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SetupCard extends StatelessWidget {
  const _SetupCard({required this.controller});
  final GrillController controller;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Card.filled(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Find your grill',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 6),
            const Text(
              'We will look for a nearby BLE device whose name begins with GRILL, save its ID, then connect over Wi-Fi.',
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => controller.discoverAndSave(),
              icon: const Icon(Icons.bluetooth_searching),
              label: const Text('Discover grill'),
            ),
          ],
        ),
      ),
    ),
  );
}

class _PowerCard extends StatelessWidget {
  const _PowerCard({required this.controller});
  final GrillController controller;

  @override
  Widget build(BuildContext context) {
    final on = controller.powerOn;
    final color = on == true
        ? const Color(0xff2e7d5b)
        : const Color(0xff514a43);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () async {
          if (on != null) {
            final confirmed = await showDialog<bool>(
              context: context,
              builder: (_) => AlertDialog(
                title: Text(on ? 'Turn grill off?' : 'Turn grill on?'),
                content: const Text('Confirm this grill power change.'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(on ? 'Turn off' : 'Turn on'),
                  ),
                ],
              ),
            );
            if (confirmed != true) return;
          }
          await controller.togglePower();
        },
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [color, Color.lerp(color, Colors.black, .22)!],
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: .15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.power_settings_new,
                  color: Colors.white,
                  size: 30,
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'GRILL POWER',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: .72),
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                      ),
                    ),
                    Text(
                      on == null
                          ? 'Checking…'
                          : on
                          ? 'On'
                          : 'Off',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 34,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: Colors.white.withValues(alpha: .8),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GrillTemperatureCard extends StatelessWidget {
  const _GrillTemperatureCard({required this.controller});
  final GrillController controller;

  @override
  Widget build(BuildContext context) => Card.filled(
    color: Colors.white,
    child: Padding(
      padding: const EdgeInsets.all(22),
      child: Row(
        children: [
          Expanded(
            child: _TemperatureValue(
              label: 'GRILL',
              value: controller.grillTemperature,
              unit: controller.fahrenheit ? '°F' : '°C',
            ),
          ),
          Container(
            width: 1,
            height: 70,
            color: Theme.of(context).dividerColor,
          ),
          Expanded(
            child: InkWell(
              onTap: () => _temperatureDialog(
                context,
                controller.grillTarget ?? 225,
                'Grill target',
                controller.setGrillTarget,
                minimum: controller.fahrenheit
                    ? GrillProtocol.minimumGrillFahrenheit
                    : GrillProtocol.minimumGrillCelsius,
                maximum: controller.fahrenheit
                    ? GrillProtocol.maximumGrillFahrenheit
                    : GrillProtocol.maximumGrillCelsius,
                unit: controller.fahrenheit ? '°F' : '°C',
              ),
              child: _TemperatureValue(
                label: 'TARGET · TAP TO SET',
                value: controller.grillTarget,
                unit: controller.fahrenheit ? '°F' : '°C',
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _TemperatureValue extends StatelessWidget {
  const _TemperatureValue({
    required this.label,
    required this.value,
    required this.unit,
  });
  final String label;
  final int? value;
  final String unit;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: const Color(0xff776c61),
          fontWeight: FontWeight.w700,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        value == null || value! < 0 ? '—' : '$value$unit',
        style: Theme.of(
          context,
        ).textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w700),
      ),
    ],
  );
}

class _ProbeCard extends StatelessWidget {
  const _ProbeCard({required this.controller, required this.index});
  final GrillController controller;
  final int index;

  @override
  Widget build(BuildContext context) {
    final current = controller.probeTemperatures[index];
    final target = controller.probeTargets[index];
    return Card.filled(
      color: Colors.white,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _temperatureDialog(
          context,
          target > 0 ? target : 165,
          'Probe ${index + 1} target',
          (value) => controller.setProbeTarget(index + 1, value),
          minimum: controller.fahrenheit
              ? GrillProtocol.minimumProbeFahrenheit
              : GrillProtocol.minimumProbeCelsius,
          maximum: controller.fahrenheit
              ? GrillProtocol.maximumProbeFahrenheit
              : GrillProtocol.maximumProbeCelsius,
          unit: controller.fahrenheit ? '°F' : '°C',
        ),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              Icon(
                Icons.thermostat,
                color: current < 0
                    ? Colors.grey
                    : Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Probe ${index + 1}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      current < 0
                          ? 'Not connected'
                          : '$current${controller.fahrenheit ? '°F' : '°C'}',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ],
                ),
              ),
              Text(
                target < 0 ? 'Set target' : 'Target $target°',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AdvancedCard extends StatelessWidget {
  const _AdvancedCard({required this.controller});
  final GrillController controller;

  @override
  Widget build(BuildContext context) => Card.filled(
    color: Colors.white,
    child: ExpansionTile(
      title: const Text('Advanced & diagnostics'),
      subtitle: Text(controller.deviceId ?? 'No Grill ID'),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
      children: [
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: true, label: Text('°F')),
            ButtonSegment(value: false, label: Text('°C')),
          ],
          selected: {controller.fahrenheit},
          onSelectionChanged: (value) =>
              controller.setUnits(useFahrenheit: value.first),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: controller.discoverAndSave,
              icon: const Icon(Icons.bluetooth_searching),
              label: const Text('BLE discovery'),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: controller.clearSavedId,
              child: const Text('Forget grill'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: controller.provisioningWifi
                ? null
                : () => _wifiSetupDialog(context, controller),
            icon: controller.provisioningWifi
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.wifi_password),
            label: Text(
              controller.provisioningWifi
                  ? 'Setting up Wi-Fi…'
                  : 'Set up grill Wi-Fi',
            ),
          ),
        ),
        const Divider(height: 28),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'Activity log',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxHeight: 240),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xff25221f),
            borderRadius: BorderRadius.circular(10),
          ),
          child: SingleChildScrollView(
            child: SelectableText(
              controller.logs.isEmpty
                  ? 'Waiting for activity…'
                  : controller.logs.join('\n'),
              style: const TextStyle(
                color: Color(0xffd9d1c7),
                fontFamily: 'monospace',
                fontSize: 11,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

Future<void> _wifiSetupDialog(
  BuildContext context,
  GrillController controller,
) async {
  final ssid = TextEditingController();
  final password = TextEditingController();
  var obscurePassword = true;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Set up grill Wi-Fi'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'The grill supports 2.4 GHz Wi-Fi. Keep your phone or tablet '
                'near the grill while the settings are sent over Bluetooth.',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: ssid,
                decoration: const InputDecoration(
                  labelText: 'Wi-Fi network name',
                  prefixIcon: Icon(Icons.wifi),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: password,
                obscureText: obscurePassword,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'Wi-Fi password',
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    onPressed: () =>
                        setState(() => obscurePassword = !obscurePassword),
                    icon: Icon(
                      obscurePassword ? Icons.visibility : Icons.visibility_off,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              try {
                await controller.provisionWifi(ssid.text, password.text);
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              } catch (error) {
                if (!dialogContext.mounted) return;
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  SnackBar(content: Text('Wi-Fi setup failed: $error')),
                );
              }
            },
            child: const Text('Send to grill'),
          ),
        ],
      ),
    ),
  );
  ssid.dispose();
  password.dispose();
}

Future<void> _temperatureDialog(
  BuildContext context,
  int initial,
  String title,
  ValueChanged<int> onSave, {
  required int minimum,
  required int maximum,
  required String unit,
}) async {
  final result = await showDialog<int>(
    context: context,
    builder: (context) => _TemperatureDialog(
      initial: initial,
      title: title,
      minimum: minimum,
      maximum: maximum,
      unit: unit,
    ),
  );
  if (result != null) onSave(result);
}

class _TemperatureDialog extends StatefulWidget {
  const _TemperatureDialog({
    required this.initial,
    required this.title,
    required this.minimum,
    required this.maximum,
    required this.unit,
  });

  final int initial;
  final String title;
  final int minimum;
  final int maximum;
  final String unit;

  @override
  State<_TemperatureDialog> createState() => _TemperatureDialogState();
}

class _TemperatureDialogState extends State<_TemperatureDialog> {
  late int value;
  late final TextEditingController textController;
  String? validationMessage;

  @override
  void initState() {
    super.initState();
    value = widget.initial.clamp(widget.minimum, widget.maximum);
    textController = TextEditingController(text: value.toString());
  }

  @override
  void dispose() {
    textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$value${widget.unit}',
          style: Theme.of(context).textTheme.displayMedium,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: textController,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
            labelText: 'Temperature',
            suffixText: widget.unit,
            errorText: validationMessage,
            helperText:
                'Allowed range: ${widget.minimum}–${widget.maximum}${widget.unit}',
          ),
          onChanged: (text) {
            final typed = int.tryParse(text);
            setState(() {
              if (typed == null ||
                  typed < widget.minimum ||
                  typed > widget.maximum) {
                validationMessage =
                    'Enter a value from ${widget.minimum} to ${widget.maximum}';
              } else {
                value = typed;
                validationMessage = null;
              }
            });
          },
        ),
        const SizedBox(height: 8),
        Slider(
          min: widget.minimum.toDouble(),
          max: widget.maximum.toDouble(),
          divisions: widget.maximum - widget.minimum,
          value: value.toDouble(),
          onChanged: (next) {
            final rounded = next.round();
            setState(() {
              value = rounded;
              validationMessage = null;
              final text = rounded.toString();
              textController.value = TextEditingValue(
                text: text,
                selection: TextSelection.collapsed(offset: text.length),
              );
            });
          },
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: validationMessage == null && textController.text.isNotEmpty
            ? () => Navigator.pop(context, value)
            : null,
        child: const Text('Set temperature'),
      ),
    ],
  );
}

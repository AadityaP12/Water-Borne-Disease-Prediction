import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:go_router/go_router.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import '../services/api.dart';

class GovDashboard extends StatefulWidget {
  const GovDashboard({super.key});

  @override
  State<GovDashboard> createState() => _GovDashboardState();
}

class _GovDashboardState extends State<GovDashboard> {
  int _activeTab = 0;

  // Overview
  Map<String, dynamic>? _overview;
  List<String> _ageLabels = [];
  List<double> _ageData = [];
  List<String> _symptomLabels = [];
  List<double> _symptomData = [];
  List<Map<String, dynamic>> _pieData = [];
  bool _loadingOverview = true;
  String? _overviewError;

  // Alerts
  List<dynamic> _alerts = [];
  bool _loadingAlerts = false;
  String? _alertsError;

  // Workers
  List<dynamic> _workers = [];
  bool _loadingWorkers = false;
  String? _workersError;

  @override
  void initState() {
    super.initState();
    _registerFcmToken();
    _fetchOverview();
  }

  Future<void> _registerFcmToken() async {
    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission();
      final token = await messaging.getToken();
      if (token != null) {
        await ApiService.request(
          '/auth/update-push-token',
          method: 'POST',
          body: {'push_token': token},
        );
      }
    } catch (e) {
      // FCM registration failure is non-fatal
    }
  }

  Future<void> _fetchOverview() async {
    setState(() { _loadingOverview = true; _overviewError = null; });
    try {
      final results = await Future.wait([
        ApiService.request('/dashboard/overview'),
        ApiService.request('/data/age-distribution'),
        ApiService.request('/data/symptom-frequency'),
        ApiService.request('/data/water-source-distribution'),
      ]);

      final overview = results[0] as Map<String, dynamic>;
      final age = results[1] as Map<String, dynamic>;
      final symptom = results[2] as Map<String, dynamic>;
      final water = results[3] as List;

      setState(() {
        _overview = overview;
        _ageLabels = List<String>.from(age['labels'] ?? []);
        _ageData = (age['datasets']?[0]?['data'] as List? ?? [])
            .map((v) => (v as num).toDouble())
            .toList();
        _symptomLabels = List<String>.from(symptom['labels'] ?? []);
        _symptomData = (symptom['datasets']?[0]?['data'] as List? ?? [])
            .map((v) => (v as num).toDouble())
            .toList();
        _pieData = water.map((e) => Map<String, dynamic>.from(e)).toList();
      });
    } catch (e) {
      setState(() => _overviewError = e.toString().replaceAll('Exception: ', ''));
    } finally {
      setState(() => _loadingOverview = false);
    }
  }

  Future<void> _fetchAlerts() async {
    setState(() { _loadingAlerts = true; _alertsError = null; });
    try {
      final data = await ApiService.request('/alerts');
      setState(() => _alerts = data['alerts'] ?? []);
    } catch (e) {
      setState(() => _alertsError = e.toString().replaceAll('Exception: ', ''));
    } finally {
      setState(() => _loadingAlerts = false);
    }
  }

  Future<void> _fetchWorkers() async {
    setState(() { _loadingWorkers = true; _workersError = null; });
    try {
      final data = await ApiService.request('/data/workers');
      setState(() => _workers = data['workers'] ?? []);
    } catch (e) {
      setState(() => _workersError = e.toString().replaceAll('Exception: ', ''));
    } finally {
      setState(() => _loadingWorkers = false);
    }
  }

  Future<void> _resolveAlert(String alertId) async {
    try {
      await ApiService.request('/alerts/$alertId/resolve', method: 'PATCH');
      setState(() => _alerts.removeWhere((a) => a['id'] == alertId));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Alert resolved'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString()), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _onTabChanged(int index) {
    setState(() => _activeTab = index);
    if (index == 0 && _overview == null) _fetchOverview();
    if (index == 1 && _alerts.isEmpty) _fetchAlerts();
    if (index == 2 && _workers.isEmpty) _fetchWorkers();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        children: [
          Expanded(child: [
            _buildOverviewTab(),
            _buildAlertsTab(),
            _buildWorkersTab(),
            _buildProfileTab(),
          ][_activeTab]),
          _buildTabBar(),
        ],
      ),
    );
  }

  // ── OVERVIEW ──────────────────────────────────────────────────

  Widget _buildOverviewTab() {
    if (_loadingOverview) {
      return const Center(child: CircularProgressIndicator(color: Color(0xFF007AFF)));
    }
    if (_overviewError != null) {
      return _errorWidget(_overviewError!, _fetchOverview);
    }
    if (_overview == null) return const SizedBox();

    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _fetchOverview,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('📊 Health & Water Overview',
                  style: TextStyle(
                      fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF007AFF))),
              const SizedBox(height: 20),

              // Stats cards
              Row(children: [
                _statCard('${_overview!['total_submissions']}', 'Submissions', const Color(0xFFe7f3ff)),
                const SizedBox(width: 12),
                _statCard('${_overview!['total_persons']}', 'Total Persons', const Color(0xFFfff3cd)),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                _statCard('${_overview!['total_at_risk']}', 'At Risk', const Color(0xFFf8d7da)),
                const SizedBox(width: 12),
                _statCard('${_overview!['active_alerts']}', 'Active Alerts', const Color(0xFFd4edda)),
              ]),

              // Water risk breakdown
              const SizedBox(height: 20),
              const Text('Water Risk Breakdown',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              Row(children: [
                _riskBadge('${_overview!['water_risk_breakdown']?['high'] ?? 0}', 'High', const Color(0xFFf8d7da)),
                const SizedBox(width: 10),
                _riskBadge('${_overview!['water_risk_breakdown']?['medium'] ?? 0}', 'Medium', const Color(0xFFfff3cd)),
                const SizedBox(width: 10),
                _riskBadge('${_overview!['water_risk_breakdown']?['low'] ?? 0}', 'Low', const Color(0xFFd4edda)),
              ]),

              // Age distribution bar chart
              if (_ageData.isNotEmpty) ...[
                const SizedBox(height: 28),
                const Text('Age Distribution',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 12),
                SizedBox(
                  height: 200,
                  child: BarChart(
                    BarChartData(
                      alignment: BarChartAlignment.spaceAround,
                      maxY: _ageData.reduce((a, b) => a > b ? a : b) * 1.3,
                      barTouchData: BarTouchData(enabled: false),
                      titlesData: FlTitlesData(
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            getTitlesWidget: (value, meta) {
                              final i = value.toInt();
                              if (i >= 0 && i < _ageLabels.length) {
                                return Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(_ageLabels[i],
                                      style: const TextStyle(fontSize: 10)),
                                );
                              }
                              return const SizedBox();
                            },
                          ),
                        ),
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(showTitles: true, reservedSize: 28),
                        ),
                        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      ),
                      gridData: const FlGridData(show: false),
                      borderData: FlBorderData(show: false),
                      barGroups: List.generate(_ageData.length, (i) => BarChartGroupData(
                        x: i,
                        barRods: [BarChartRodData(
                          toY: _ageData[i],
                          color: const Color(0xFF007AFF),
                          width: 20,
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                        )],
                      )),
                    ),
                  ),
                ),
              ],

              // Symptom frequency bar chart
              if (_symptomData.isNotEmpty) ...[
                const SizedBox(height: 28),
                const Text('Symptom Frequency',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 12),
                SizedBox(
                  height: 220,
                  child: BarChart(
                    BarChartData(
                      alignment: BarChartAlignment.spaceAround,
                      maxY: _symptomData.isEmpty ? 10 : _symptomData.reduce((a, b) => a > b ? a : b) * 1.3,
                      barTouchData: BarTouchData(enabled: false),
                      titlesData: FlTitlesData(
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            getTitlesWidget: (value, meta) {
                              final i = value.toInt();
                              if (i >= 0 && i < _symptomLabels.length) {
                                final words = _symptomLabels[i].split(' ');
                                return Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    words.first,
                                    style: const TextStyle(fontSize: 9),
                                  ),
                                );
                              }
                              return const SizedBox();
                            },
                          ),
                        ),
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(showTitles: true, reservedSize: 28),
                        ),
                        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      ),
                      gridData: const FlGridData(show: false),
                      borderData: FlBorderData(show: false),
                      barGroups: List.generate(_symptomData.length, (i) => BarChartGroupData(
                        x: i,
                        barRods: [BarChartRodData(
                          toY: _symptomData[i],
                          color: const Color(0xFFFF6384),
                          width: 16,
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                        )],
                      )),
                    ),
                  ),
                ),
              ],

              // Water source pie chart
              if (_pieData.isNotEmpty) ...[
                const SizedBox(height: 28),
                const Text('Water Source Distribution',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 12),
                SizedBox(
                  height: 220,
                  child: PieChart(
                    PieChartData(
                      sectionsSpace: 2,
                      centerSpaceRadius: 40,
                      sections: _pieData.map((d) {
                        final color = _hexToColor(d['color'] as String? ?? '#007AFF');
                        final total = _pieData.fold<int>(0, (sum, e) => sum + (e['population'] as int));
                        final pct = total > 0 ? (d['population'] as int) / total * 100 : 0.0;
                        return PieChartSectionData(
                          color: color,
                          value: (d['population'] as int).toDouble(),
                          title: '${pct.toStringAsFixed(0)}%',
                          radius: 70,
                          titleStyle: const TextStyle(
                              fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white),
                        );
                      }).toList(),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 12,
                  runSpacing: 6,
                  children: _pieData.map((d) => Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 12, height: 12,
                        decoration: BoxDecoration(
                          color: _hexToColor(d['color'] as String? ?? '#007AFF'),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text('${d['name']} (${d['population']})',
                          style: const TextStyle(fontSize: 12)),
                    ],
                  )).toList(),
                ),
              ],

              // Recent records
              const SizedBox(height: 28),
              const Text('Recent Submissions',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              ...(_overview!['recent_records'] as List? ?? []).reversed.map((r) {
                final sources = r['water_sources'] as List? ?? [];
                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFf8f9fa),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('House: ${r['house_id'] ?? 'N/A'}  ·  ${r['village'] ?? r['district'] ?? ''}',
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                      Text('${r['persons_with_symptoms']}/${r['total_persons']} at risk',
                          style: const TextStyle(fontSize: 13, color: Colors.grey)),
                      const SizedBox(height: 6),
                      if (sources.isNotEmpty)
                        Wrap(
                          spacing: 6, runSpacing: 4,
                          children: sources.map((s) {
                            final risk = s['risk_level'] as String? ?? 'low';
                            final c = risk == 'high' ? const Color(0xFFf8d7da)
                                : risk == 'medium' ? const Color(0xFFfff3cd)
                                : const Color(0xFFd4edda);
                            return Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(10)),
                              child: Text('${s['source_name']}: ${risk.toUpperCase()} (${(s['risk_percent'] as num?)?.toInt() ?? 0}%)',
                                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                            );
                          }).toList(),
                        ),
                    ],
                  ),
                );
              }),
              const SizedBox(height: 80),
            ],
          ),
        ),
      ),
    );
  }

  // ── ALERTS ────────────────────────────────────────────────────

  Widget _buildAlertsTab() {
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('🚨 Active Alerts',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF007AFF))),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: _fetchAlerts,
                ),
              ],
            ),
          ),
          Expanded(
            child: _loadingAlerts
                ? const Center(child: CircularProgressIndicator(color: Color(0xFF007AFF)))
                : _alertsError != null
                    ? _errorWidget(_alertsError!, _fetchAlerts)
                    : _alerts.isEmpty
                        ? const Center(child: Text('No active alerts', style: TextStyle(color: Colors.grey, fontSize: 16)))
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            itemCount: _alerts.length,
                            itemBuilder: (_, i) {
                              final alert = _alerts[i];
                              final location = [alert['village'], alert['block'], alert['district'], alert['state']]
                                  .where((x) => x != null && x != '').join(', ');
                              return Container(
                                margin: const EdgeInsets.only(bottom: 12),
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFfff3f3),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: const Color(0xFFf5c6cb)),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text((alert['severity'] ?? '').toString().toUpperCase(),
                                            style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFFdc3545), fontSize: 13)),
                                        Text((alert['created_at'] ?? '').toString().substring(0, 10),
                                            style: const TextStyle(fontSize: 12, color: Colors.grey)),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(alert['source_name'] ?? '',
                                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                                    if (location.isNotEmpty)
                                      Text(location, style: const TextStyle(fontSize: 13, color: Colors.grey)),
                                    Text('Water risk: ${(alert['risk_percent'] as num?)?.toInt() ?? 0}%',
                                        style: const TextStyle(fontSize: 13, color: Color(0xFFdc3545))),
                                    const SizedBox(height: 10),
                                    ElevatedButton(
                                      onPressed: () => _resolveAlert(alert['id'].toString()),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(0xFF28a745),
                                        foregroundColor: Colors.white,
                                        minimumSize: const Size(double.infinity, 36),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                                      ),
                                      child: const Text('Mark Resolved', style: TextStyle(fontWeight: FontWeight.bold)),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
          ),
        ],
      ),
    );
  }

  // ── WORKERS ───────────────────────────────────────────────────

  Widget _buildWorkersTab() {
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('👥 ASHA Workers',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF007AFF))),
                IconButton(icon: const Icon(Icons.refresh), onPressed: _fetchWorkers),
              ],
            ),
          ),
          if (!_loadingWorkers && !_workers.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFe7f3ff),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    Column(children: [
                      Text('${_workers.length}',
                          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Color(0xFF007AFF))),
                      const Text('Active Workers', style: TextStyle(fontSize: 12, color: Colors.grey)),
                    ]),
                    Column(children: [
                      Text('${_workers.fold<int>(0, (sum, w) => sum + (w['submissions'] as int? ?? 0))}',
                          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Color(0xFF007AFF))),
                      const Text('Total Submissions', style: TextStyle(fontSize: 12, color: Colors.grey)),
                    ]),
                  ],
                ),
              ),
            ),
          Expanded(
            child: _loadingWorkers
                ? const Center(child: CircularProgressIndicator(color: Color(0xFF007AFF)))
                : _workersError != null
                    ? _errorWidget(_workersError!, _fetchWorkers)
                    : _workers.isEmpty
                        ? const Center(child: Text('No workers found', style: TextStyle(color: Colors.grey)))
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            itemCount: _workers.length,
                            itemBuilder: (_, i) {
                              final w = _workers[i];
                              return Container(
                                margin: const EdgeInsets.only(bottom: 10),
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFf8f9fa),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 40, height: 40,
                                      decoration: const BoxDecoration(
                                        color: Color(0xFF007AFF),
                                        shape: BoxShape.circle,
                                      ),
                                      child: Center(
                                        child: Text(
                                          (w['full_name'] as String? ?? 'A').substring(0, 1).toUpperCase(),
                                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(w['full_name'] ?? '',
                                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                                          Text('${w['district']}, ${w['state']}',
                                              style: const TextStyle(fontSize: 12, color: Colors.grey)),
                                        ],
                                      ),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFe7f3ff),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Text('${w['submissions']} submissions',
                                          style: const TextStyle(fontSize: 12, color: Color(0xFF007AFF), fontWeight: FontWeight.bold)),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
          ),
        ],
      ),
    );
  }

  // ── PROFILE ───────────────────────────────────────────────────

  Widget _buildProfileTab() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('👤 Profile',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF007AFF))),
            const SizedBox(height: 20),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                  color: const Color(0xFFf8f9fa), borderRadius: BorderRadius.circular(10)),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Government Dashboard', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  SizedBox(height: 4),
                  Text('Northeast India — Water Disease Monitoring',
                      style: TextStyle(fontSize: 14, color: Colors.grey)),
                  SizedBox(height: 4),
                  Text('Access Level: District Administrator',
                      style: TextStyle(fontSize: 14, color: Colors.grey)),
                ],
              ),
            ),
            const SizedBox(height: 20),
            OutlinedButton(
              onPressed: () async {
                await ApiService.clearToken();
                await ApiService.clearUser();
                if (mounted) context.go('/login');
              },
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red,
                side: const BorderSide(color: Colors.red),
                minimumSize: const Size(double.infinity, 50),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('Logout', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  // ── TAB BAR ───────────────────────────────────────────────────

  Widget _buildTabBar() {
    final tabs = [
      {'icon': Icons.bar_chart, 'label': 'Overview'},
      {'icon': Icons.warning_amber, 'label': 'Alerts'},
      {'icon': Icons.people, 'label': 'Workers'},
      {'icon': Icons.person, 'label': 'Profile'},
    ];
    return Container(
      height: 60,
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFFdddddd))),
        color: Color(0xFFf9f9f9),
      ),
      child: Row(
        children: List.generate(tabs.length, (i) {
          final active = _activeTab == i;
          return Expanded(
            child: InkWell(
              onTap: () => _onTabChanged(i),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(tabs[i]['icon'] as IconData,
                      color: active ? const Color(0xFF007AFF) : Colors.grey, size: 20),
                  Text(tabs[i]['label'] as String,
                      style: TextStyle(
                          fontSize: 10,
                          color: active ? const Color(0xFF007AFF) : Colors.grey,
                          fontWeight: active ? FontWeight.bold : FontWeight.normal)),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }

  // ── HELPERS ───────────────────────────────────────────────────

  Widget _statCard(String num, String label, Color color) => Expanded(
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(10)),
          child: Column(children: [
            Text(num, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Color(0xFF333333))),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(fontSize: 13, color: Color(0xFF555555))),
          ]),
        ),
      );

  Widget _riskBadge(String num, String label, Color color) => Expanded(
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
          child: Column(children: [
            Text(num, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ]),
        ),
      );

  Widget _errorWidget(String error, VoidCallback onRetry) => Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: const Color(0xFFfff3cd), borderRadius: BorderRadius.circular(10)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(error, style: const TextStyle(color: Color(0xFF856404))),
                const SizedBox(height: 10),
                ElevatedButton(onPressed: onRetry, child: const Text('Retry')),
              ],
            ),
          ),
        ),
      );

  Color _hexToColor(String hex) {
    final h = hex.replaceAll('#', '');
    return Color(int.parse('FF$h', radix: 16));
  }
}
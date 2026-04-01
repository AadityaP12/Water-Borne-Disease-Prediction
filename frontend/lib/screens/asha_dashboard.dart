import 'package:flutter/material.dart';
import 'package:firebase_messaging/firebase_messaging.dart' as firebase_messaging;
import 'package:go_router/go_router.dart';
import '../services/api.dart';

class AshaDashboard extends StatefulWidget {
  const AshaDashboard({super.key});

  @override
  State<AshaDashboard> createState() => _AshaDashboardState();
}

class _AshaDashboardState extends State<AshaDashboard> {
  int _activeTab = 0;
  int _step = 0; // 0=location, 1=persons, 2=water sources

  // Step 0 — Location
  final _houseIdCtrl = TextEditingController();
  final _stateCtrl = TextEditingController();
  final _districtCtrl = TextEditingController();
  final _blockCtrl = TextEditingController();
  final _villageCtrl = TextEditingController();

  // Step 1 — Persons
  final List<Map<String, dynamic>> _persons = [];

  // Step 2 — Water sources
  final List<Map<String, dynamic>> _waterSources = [];

  bool _submitting = false;

  // History
  List<dynamic> _history = [];
  bool _loadingHistory = false;
  String? _historyError;

  // Values MUST match Water_Quality_Dataset_Refined.csv source_type column exactly
  // (used by OneHotEncoder in water ML model — unknown values silently zero out)
  final _sourceTypes = const [
    {'label': 'Deep Borehole',     'value': 'deep_borehole'},
    {'label': 'Piped / Protected', 'value': 'piped_protected'},
    {'label': 'Community Tank',    'value': 'community_tank'},
    {'label': 'Shallow Well',      'value': 'shallow_well'},
    {'label': 'Spring',            'value': 'spring'},
    {'label': 'River',             'value': 'river'},
    {'label': 'Pond',              'value': 'pond'},
    {'label': 'Reservoir',         'value': 'reservoir'},
    {'label': 'Canal',             'value': 'canal'},
    {'label': 'Rooftop Rainwater', 'value': 'rooftop_rainwater'},
    {'label': 'Open Catchment',    'value': 'open_catchment'},
  ];

  // FIX: 'Rain' renamed to 'Monsoon' — must match Water_Quality_Dataset_Refined.csv
  // season column exactly. 'Rain' is not a training value and would zero out the
  // OneHotEncoder category, producing biased risk predictions.
  final _seasons = const ['Winter', 'Summer', 'Autumn', 'Monsoon'];

  final _symptomList = const [
    'diarrhea', 'fatigue', 'vomiting', 'fever',
    'jaundice', 'headache', 'loss_of_appetite', 'muscle_aches',
  ];

  // Symptoms that support severity 0/1/2 in the training data.
  // All other symptoms are binary (0/1 only).
  static const _severitySymptoms = {'diarrhea', 'fatigue'};

  @override
  void initState() {
    super.initState();
    _prefillDefaults();
    _fetchHistory();
    _registerFcmToken();
  }

  void _prefillDefaults() {
    _houseIdCtrl.text  = 'HH-001';
    _stateCtrl.text    = 'Assam';
    _districtCtrl.text = 'Kamrup';
    _blockCtrl.text    = 'Guwahati';
    _villageCtrl.text  = 'Jalukbari';

    _persons.add({
      'sex':              'male',
      'age':              35,
      'sanitation':       'poor',
      'water_source':     'shallow_well',
      'diarrhea':         2,
      'fatigue':          1,
      'vomiting':         0,
      'fever':            1,
      'jaundice':         0,
      'headache':         1,
      'loss_of_appetite': 1,
      'muscle_aches':     0,
    });

    _waterSources.add({
      'name':             'Village Well',
      'source_type':      'shallow_well',
      'season':           'Monsoon',
      'month':            DateTime.now().month,
      'ph':               6.5,
      'turbidity':        12.0,
      'temperature':      28.0,
      'rainfall':         45.0,
      'dissolved_oxygen': 5.2,
      'chlorine':         0.1,
      'fecal_coliform':   180.0,
      'hardness':         210.0,
      'nitrate':          18.0,
      'tds':              520.0,
    });
  }

  Future<void> _registerFcmToken() async {
    try {
      final messaging = firebase_messaging.FirebaseMessaging.instance;
      final settings = await messaging.requestPermission();
      if (settings.authorizationStatus ==
          firebase_messaging.AuthorizationStatus.authorized) {
        final token = await messaging.getToken();
        if (token != null) {
          await ApiService.request(
            '/auth/update-push-token',
            method: 'POST',
            body: {'push_token': token},
          );
        }
      }
    } catch (e) {
      // Non-fatal — app works without push notifications
      debugPrint('FCM setup failed: $e');
    }
  }

  @override
  void dispose() {
    _houseIdCtrl.dispose();
    _stateCtrl.dispose();
    _districtCtrl.dispose();
    _blockCtrl.dispose();
    _villageCtrl.dispose();
    _curPwCtrl.dispose();
    _newPwCtrl.dispose();
    _confPwCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetchHistory() async {
    setState(() { _loadingHistory = true; _historyError = null; });
    try {
      final data = await ApiService.request('/data/history');
      setState(() => _history = data['records'] ?? []);
    } catch (e) {
      setState(() => _historyError = e.toString().replaceAll('Exception: ', ''));
    } finally {
      setState(() => _loadingHistory = false);
    }
  }

  Future<void> _handleSubmit() async {
    setState(() => _submitting = true);
    try {
      final body = {
        'house_id':      _houseIdCtrl.text,
        'state':         _stateCtrl.text,
        'district':      _districtCtrl.text,
        'block':         _blockCtrl.text,
        'village':       _villageCtrl.text,
        'persons':       _persons,
        'water_sources': _waterSources,
      };

      final data = await ApiService.request('/data/submit', method: 'POST', body: body);
      if (!mounted) return;

      final healthResult = data['health'];
      final waterResults = data['water_sources'] as List;
      final alertsCreated = data['alerts_created'] ?? 0;

      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Prediction Result'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Health: ${healthResult['persons_with_symptoms']}/${healthResult['total_persons']} persons at risk',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                const Text('Water Sources:', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                ...waterResults.map((w) {
                  final risk = w['risk_level'] as String;
                  final color = risk == 'high'
                      ? Colors.red.shade100
                      : risk == 'medium'
                          ? Colors.orange.shade100
                          : Colors.green.shade100;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                        color: color, borderRadius: BorderRadius.circular(8)),
                    child: Text(
                      '${w['source_name']}: ${risk.toUpperCase()} (${(w['risk_percent'] as num?)?.toInt() ?? 0}%)',
                      style: const TextStyle(fontSize: 13),
                    ),
                  );
                }),
                if (alertsCreated > 0) ...[
                  const SizedBox(height: 12),
                  Text(
                    '⚠️ $alertsCreated alert(s) sent to district officials!',
                    style: const TextStyle(
                        color: Colors.red, fontWeight: FontWeight.bold),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                _resetForm();
                setState(() => _activeTab = 1);
                _fetchHistory();
              },
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } catch (e) {
      _showError(e.toString().replaceAll('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _resetForm() {
    setState(() {
      _step = 0;
      _persons.clear();
      _waterSources.clear();
      _houseIdCtrl.clear();
      _stateCtrl.clear();
      _districtCtrl.clear();
      _blockCtrl.clear();
      _villageCtrl.clear();
    });
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red),
    );
  }

  void _showAddPersonDialog() {
    String sex = 'male';
    String sanitation = 'poor';
    final ageCtrl = TextEditingController();
    final symptoms = <String, int>{for (var s in _symptomList) s: 0};

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Add Person'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Age *', style: TextStyle(fontWeight: FontWeight.w600)),
                TextField(
                  controller: ageCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(hintText: 'e.g. 35'),
                ),
                const SizedBox(height: 12),
                const Text('Sex', style: TextStyle(fontWeight: FontWeight.w600)),
                // FIX: removed 'other' — health model only trained on male/female.
                // 'other' would zero out the sex encoding giving biased predictions.
                DropdownButton<String>(
                  value: sex,
                  isExpanded: true,
                  items: ['male', 'female']
                      .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                      .toList(),
                  onChanged: (v) => setS(() => sex = v!),
                ),
                const SizedBox(height: 8),
                const Text('Sanitation', style: TextStyle(fontWeight: FontWeight.w600)),
                DropdownButton<String>(
                  value: sanitation,
                  isExpanded: true,
                  items: ['poor', 'good']
                      .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                      .toList(),
                  onChanged: (v) => setS(() => sanitation = v!),
                ),
                const SizedBox(height: 12),
                // FIX: diarrhea and fatigue support 0/1/2 (trained with severity).
                // All other symptoms are binary (0/1 only) in the training data.
                // Showing 0/1/2 for binary symptoms would produce out-of-distribution
                // inputs and unreliable predictions.
                const Text(
                  'Symptoms\n  diarrhea & fatigue: 0=None  1=Mild  2=Severe\n  others: 0=No  1=Yes',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                ),
                const SizedBox(height: 8),
                ...(_symptomList.map((s) => Row(
                      children: [
                        Expanded(
                            child: Text(s.replaceAll('_', ' '),
                                style: const TextStyle(fontSize: 13))),
                        DropdownButton<int>(
                          value: symptoms[s],
                          // FIX: only diarrhea and fatigue get severity level 2
                          items: (_severitySymptoms.contains(s) ? [0, 1, 2] : [0, 1])
                              .map((v) =>
                                  DropdownMenuItem(value: v, child: Text('$v')))
                              .toList(),
                          onChanged: (v) => setS(() => symptoms[s] = v!),
                        ),
                      ],
                    ))),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                if (ageCtrl.text.isEmpty) return;
                setState(() {
                  _persons.add({
                    'sex':              sex,
                    'age':              int.tryParse(ageCtrl.text) ?? 0,
                    'sanitation':       sanitation,
                    'water_source':     _waterSources.isNotEmpty
                        ? _waterSources[0]['source_type']
                        : 'shallow_well', // default must be a valid training value
                    'diarrhea':         symptoms['diarrhea'],
                    'fatigue':          symptoms['fatigue'],
                    'vomiting':         symptoms['vomiting'],
                    'fever':            symptoms['fever'],
                    'jaundice':         symptoms['jaundice'],
                    'headache':         symptoms['headache'],
                    'loss_of_appetite': symptoms['loss_of_appetite'],
                    'muscle_aches':     symptoms['muscle_aches'],
                  });
                });
                Navigator.pop(ctx);
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }

  void _showAddWaterSourceDialog() {
    final nameCtrl = TextEditingController();
    final phCtrl = TextEditingController();
    final turbCtrl = TextEditingController();
    final tempCtrl = TextEditingController();
    final rainfallCtrl = TextEditingController();
    final doCtrl = TextEditingController();
    final chlorineCtrl = TextEditingController();
    final fecalCtrl = TextEditingController();
    final hardnessCtrl = TextEditingController();
    final nitrateCtrl = TextEditingController();
    final tdsCtrl = TextEditingController();
    // FIX: default was 'well' which is not a valid training value.
    // Changed to 'shallow_well' which exists in Water_Quality_Dataset_Refined.csv.
    String sourceType = 'shallow_well';
    // FIX: default was 'Rain' which is not a valid training value.
    // Changed to 'Monsoon' which matches Water_Quality_Dataset_Refined.csv.
    String season = 'Monsoon';
    int month = DateTime.now().month;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Add Water Source'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Source Name *',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(hintText: 'e.g. Village Well')),
                const SizedBox(height: 8),
                const Text('Source Type',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                DropdownButton<String>(
                  value: sourceType,
                  isExpanded: true,
                  items: _sourceTypes
                      .map((e) => DropdownMenuItem(
                          value: e['value'], child: Text(e['label']!)))
                      .toList(),
                  onChanged: (v) => setS(() => sourceType = v!),
                ),
                const SizedBox(height: 8),
                const Text('Season', style: TextStyle(fontWeight: FontWeight.w600)),
                DropdownButton<String>(
                  value: season,
                  isExpanded: true,
                  items: _seasons
                      .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                      .toList(),
                  onChanged: (v) => setS(() => season = v!),
                ),
                const SizedBox(height: 8),
                const Text('Month (1-12)',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                DropdownButton<int>(
                  value: month,
                  isExpanded: true,
                  items: List.generate(12, (i) => DropdownMenuItem(
                      value: i + 1, child: Text('${i + 1}'))).toList(),
                  onChanged: (v) => setS(() => month = v!),
                ),
                const SizedBox(height: 8),
                const Text('Water Quality Readings (optional)',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                _dialogField('pH', phCtrl),
                _dialogField('Turbidity (NTU)', turbCtrl),
                _dialogField('Temperature (°C)', tempCtrl),
                _dialogField('Rainfall 24h (mm)', rainfallCtrl),
                _dialogField('Dissolved Oxygen (mg/L)', doCtrl),
                _dialogField('Chlorine (mg/L)', chlorineCtrl),
                _dialogField('Fecal Coliform (CFU/100ml)', fecalCtrl),
                _dialogField('Hardness (mg/L)', hardnessCtrl),
                _dialogField('Nitrate (mg/L)', nitrateCtrl),
                _dialogField('TDS (mg/L)', tdsCtrl),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                if (nameCtrl.text.isEmpty) return;
                setState(() {
                  _waterSources.add({
                    'name':        nameCtrl.text,
                    'source_type': sourceType,
                    'season':      season,
                    'month':       month,
                    if (phCtrl.text.isNotEmpty)        'ph':               double.tryParse(phCtrl.text),
                    if (turbCtrl.text.isNotEmpty)      'turbidity':        double.tryParse(turbCtrl.text),
                    if (tempCtrl.text.isNotEmpty)      'temperature':      double.tryParse(tempCtrl.text),
                    if (rainfallCtrl.text.isNotEmpty)  'rainfall':         double.tryParse(rainfallCtrl.text),
                    if (doCtrl.text.isNotEmpty)        'dissolved_oxygen': double.tryParse(doCtrl.text),
                    if (chlorineCtrl.text.isNotEmpty)  'chlorine':         double.tryParse(chlorineCtrl.text),
                    if (fecalCtrl.text.isNotEmpty)     'fecal_coliform':   double.tryParse(fecalCtrl.text),
                    if (hardnessCtrl.text.isNotEmpty)  'hardness':         double.tryParse(hardnessCtrl.text),
                    if (nitrateCtrl.text.isNotEmpty)   'nitrate':          double.tryParse(nitrateCtrl.text),
                    if (tdsCtrl.text.isNotEmpty)       'tds':              double.tryParse(tdsCtrl.text),
                  });
                });
                Navigator.pop(ctx);
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dialogField(String label, TextEditingController ctrl) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: TextField(
          controller: ctrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: label,
            isDense: true,
            border: const OutlineInputBorder(),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        children: [
          Expanded(child: [
            _buildSubmitTab(),
            _buildHistoryTab(),
            _buildProfileTab(),
          ][_activeTab]),
          _buildTabBar(),
        ],
      ),
    );
  }

  Widget _buildSubmitTab() {
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Row(
              children: [
                _stepDot(0, 'Location'),
                const Expanded(child: Divider()),
                _stepDot(1, 'Persons'),
                const Expanded(child: Divider()),
                _stepDot(2, 'Water'),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: [_buildStep0(), _buildStep1(), _buildStep2()][_step],
            ),
          ),
        ],
      ),
    );
  }

  Widget _stepDot(int index, String label) => Column(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _step >= index ? const Color(0xFF007AFF) : Colors.grey.shade300,
            ),
            child: Center(
              child: Text('${index + 1}',
                  style: TextStyle(
                      color: _step >= index ? Colors.white : Colors.grey,
                      fontWeight: FontWeight.bold,
                      fontSize: 13)),
            ),
          ),
          Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey)),
        ],
      );

  Widget _buildStep0() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('📍 Household & Location',
              style: TextStyle(
                  fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF007AFF))),
          const SizedBox(height: 20),
          _label('House ID *'),
          _ctrl('e.g. HH-001', _houseIdCtrl),
          _label('State'),
          _ctrl('e.g. Assam', _stateCtrl),
          _label('District'),
          _ctrl('e.g. Kamrup', _districtCtrl),
          _label('Block'),
          _ctrl('e.g. Guwahati', _blockCtrl),
          _label('Village'),
          _ctrl('e.g. Jalukbari', _villageCtrl),
          const SizedBox(height: 24),
          _nextButton('Next: Add Persons →', () {
            if (_houseIdCtrl.text.isEmpty) {
              _showError('Please enter a House ID.');
              return;
            }
            setState(() => _step = 1);
          }),
        ],
      );

  Widget _buildStep1() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('👥 Persons in Household',
              style: TextStyle(
                  fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF007AFF))),
          const SizedBox(height: 8),
          Text('House: ${_houseIdCtrl.text}',
              style: const TextStyle(color: Colors.grey, fontSize: 13)),
          const SizedBox(height: 16),
          ..._persons.asMap().entries.map((e) => _personCard(e.key, e.value)),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _showAddPersonDialog,
            icon: const Icon(Icons.person_add),
            label: const Text('Add Person'),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF007AFF),
              side: const BorderSide(color: Color(0xFF007AFF)),
              minimumSize: const Size(double.infinity, 48),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
          const SizedBox(height: 24),
          _navButtons(
            onBack: () => setState(() => _step = 0),
            onNext: () {
              if (_persons.isEmpty) {
                _showError('Please add at least one person.');
                return;
              }
              setState(() => _step = 2);
            },
            nextLabel: 'Next: Water Sources →',
          ),
        ],
      );

  Widget _buildStep2() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('💧 Water Sources',
              style: TextStyle(
                  fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF007AFF))),
          const SizedBox(height: 8),
          const Text('Add all water sources used by this household.',
              style: TextStyle(color: Colors.grey, fontSize: 13)),
          const SizedBox(height: 16),
          ..._waterSources.asMap().entries.map((e) => _waterSourceCard(e.key, e.value)),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _showAddWaterSourceDialog,
            icon: const Icon(Icons.water_drop_outlined),
            label: const Text('Add Water Source'),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF007AFF),
              side: const BorderSide(color: Color(0xFF007AFF)),
              minimumSize: const Size(double.infinity, 48),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
          const SizedBox(height: 24),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => setState(() => _step = 1),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 48),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: const Text('← Back'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton(
                onPressed: _submitting
                    ? null
                    : () {
                        if (_waterSources.isEmpty) {
                          _showError('Please add at least one water source.');
                          return;
                        }
                        _handleSubmit();
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF007AFF),
                  foregroundColor: Colors.white,
                  minimumSize: const Size(0, 48),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: _submitting
                    ? const CircularProgressIndicator(color: Colors.white)
                    : const Text('Submit & Predict',
                        style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
          ]),
          const SizedBox(height: 40),
        ],
      );

  Widget _personCard(int index, Map<String, dynamic> p) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFf0f7ff),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFb3d4ff)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Person ${index + 1}: ${p['sex']}, age ${p['age']}',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(
                    _symptomList
                        .where((s) => (p[s] ?? 0) > 0)
                        .map((s) => '${s.replaceAll('_', ' ')}(${p[s]})')
                        .join(', '),
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
              onPressed: () => setState(() => _persons.removeAt(index)),
            ),
          ],
        ),
      );

  Widget _waterSourceCard(int index, Map<String, dynamic> w) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFf0fff4),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFb3e6c8)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(w['name'] ?? '',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text('${w['source_type']} · ${w['season']}',
                      style: const TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
              onPressed: () => setState(() => _waterSources.removeAt(index)),
            ),
          ],
        ),
      );

  Widget _buildHistoryTab() {
    return SafeArea(
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(20),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('📜 My Submissions',
                  style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF007AFF))),
            ),
          ),
          Expanded(
            child: _loadingHistory
                ? const Center(child: CircularProgressIndicator(color: Color(0xFF007AFF)))
                : _historyError != null
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_historyError!,
                                style: const TextStyle(color: Colors.red)),
                            const SizedBox(height: 12),
                            ElevatedButton(
                                onPressed: _fetchHistory,
                                child: const Text('Retry')),
                          ],
                        ),
                      )
                    : _history.isEmpty
                        ? const Center(
                            child: Text('No submissions yet',
                                style: TextStyle(color: Colors.grey)))
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            itemCount: _history.length,
                            itemBuilder: (_, i) {
                              final r = _history[_history.length - 1 - i];
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
                                    Text(
                                      'House: ${r['house_id'] ?? 'N/A'}  ·  ${r['village'] ?? r['district'] ?? ''}',
                                      style: const TextStyle(
                                          fontSize: 14, fontWeight: FontWeight.w600),
                                    ),
                                    Text(
                                      '${(r['persons_with_symptoms'] as num?)?.toInt() ?? 0}/${(r['total_persons'] as num?)?.toInt() ?? 0} persons at risk',
                                      style: const TextStyle(
                                          fontSize: 13, color: Colors.grey),
                                    ),
                                    const SizedBox(height: 6),
                                    if (sources.isNotEmpty)
                                      Wrap(
                                        spacing: 6,
                                        runSpacing: 4,
                                        children: sources.map((s) {
                                          final risk = s['risk_level'] as String? ?? 'low';
                                          final color = risk == 'high'
                                              ? const Color(0xFFf8d7da)
                                              : risk == 'medium'
                                                  ? const Color(0xFFfff3cd)
                                                  : const Color(0xFFd4edda);
                                          return Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 8, vertical: 3),
                                            decoration: BoxDecoration(
                                                color: color,
                                                borderRadius: BorderRadius.circular(10)),
                                            child: Text(
                                              '${s['source_name']}: ${risk.toUpperCase()} (${(s['risk_percent'] as num?)?.toInt() ?? 0}%)',
                                              style: const TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.bold),
                                            ),
                                          );
                                        }).toList(),
                                      )
                                    else
                                      _riskPill(
                                          r['water_risk_level'] ?? 'low',
                                          (r['water_risk_percent'] as num?)?.toInt() ?? 0),
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

  Widget _riskPill(String risk, dynamic percent) {
    final color = risk == 'high'
        ? const Color(0xFFf8d7da)
        : risk == 'medium'
            ? const Color(0xFFfff3cd)
            : const Color(0xFFd4edda);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration:
          BoxDecoration(color: color, borderRadius: BorderRadius.circular(12)),
      child: Text('${risk.toUpperCase()} · $percent%',
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
    );
  }

  // Profile tab state
  final _stateDistrictMap = const {
    'Arunachal Pradesh': ['Itanagar','Tawang','Pasighat','Ziro','Bomdila'],
    'Assam':             ['Guwahati','Dispur','Jorhat','Silchar','Dibrugarh'],
    'Manipur':           ['Imphal','Thoubal','Churachandpur','Bishnupur','Senapati'],
    'Meghalaya':         ['Shillong','Tura','Nongpoh','Jowai','Williamnagar'],
    'Mizoram':           ['Aizawl','Lunglei','Serchhip','Champhai','Saiha'],
    'Nagaland':          ['Kohima','Dimapur','Mokokchung','Mon','Tuensang'],
    'Sikkim':            ['Gangtok','Namchi','Geyzing','Mangan','Ravangla'],
    'Tripura':           ['Agartala','Udaipur','Dharmanagar','Kailashahar','Belonia'],
  };

  String _profileState    = '';
  String _profileDistrict = '';
  final _curPwCtrl  = TextEditingController();
  final _newPwCtrl  = TextEditingController();
  final _confPwCtrl = TextEditingController();
  String _profileError   = '';
  String _profileSuccess = '';
  bool   _profileSaving  = false;

  Future<void> _saveProfile() async {
    setState(() { _profileError = ''; _profileSuccess = ''; _profileSaving = true; });

    if (_curPwCtrl.text.isEmpty) {
      setState(() { _profileError = 'Enter your current password to confirm changes.'; _profileSaving = false; });
      return;
    }

    if (_newPwCtrl.text.isNotEmpty || _confPwCtrl.text.isNotEmpty) {
      if (_newPwCtrl.text != _confPwCtrl.text) {
        setState(() { _profileError = 'New passwords do not match.'; _profileSaving = false; });
        return;
      }
    }

    try {
      final body = <String, dynamic>{
        'current_password': _curPwCtrl.text,
        'state':    _profileState,
        'district': _profileDistrict,
        if (_newPwCtrl.text.isNotEmpty) 'new_password': _newPwCtrl.text,
      };
      await ApiService.request('/auth/update-profile', method: 'POST', body: body);
      setState(() {
        _profileSuccess = 'Profile updated successfully!';
        _curPwCtrl.clear();
        _newPwCtrl.clear();
        _confPwCtrl.clear();
      });
    } catch (e) {
      setState(() => _profileError = e.toString().replaceAll('Exception: ', ''));
    } finally {
      setState(() => _profileSaving = false);
    }
  }

  Widget _buildProfileTab() {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('👤 Profile',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF007AFF))),
            const SizedBox(height: 20),

            if (_profileError.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: const Color(0xFFf8d7da), borderRadius: BorderRadius.circular(8)),
                child: Text(_profileError, style: const TextStyle(color: Color(0xFF721c24))),
              ),
            if (_profileSuccess.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: const Color(0xFFd4edda), borderRadius: BorderRadius.circular(8)),
                child: Text(_profileSuccess, style: const TextStyle(color: Color(0xFF155724))),
              ),

            const Text('Location',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            const Text('State', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            DropdownButtonFormField<String>(
              value: _profileState.isEmpty ? null : _profileState,
              decoration: InputDecoration(
                hintText: 'Select State',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              ),
              items: _stateDistrictMap.keys
                  .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                  .toList(),
              onChanged: (v) => setState(() { _profileState = v!; _profileDistrict = ''; }),
            ),
            const SizedBox(height: 12),
            const Text('District', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            DropdownButtonFormField<String>(
              value: _profileDistrict.isEmpty ? null : _profileDistrict,
              decoration: InputDecoration(
                hintText: 'Select District',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              ),
              items: (_profileState.isNotEmpty ? _stateDistrictMap[_profileState]! : <String>[])
                  .map((d) => DropdownMenuItem(value: d, child: Text(d)))
                  .toList(),
              onChanged: (v) => setState(() => _profileDistrict = v!),
            ),

            const SizedBox(height: 24),
            const Text('Reset Password (Optional)',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            _label('Current Password *'),
            TextField(
              controller: _curPwCtrl,
              obscureText: true,
              decoration: InputDecoration(
                hintText: 'Required to save any changes',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              ),
            ),
            _label('New Password'),
            TextField(
              controller: _newPwCtrl,
              obscureText: true,
              decoration: InputDecoration(
                hintText: 'Leave blank to keep current',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              ),
            ),
            _label('Confirm New Password'),
            TextField(
              controller: _confPwCtrl,
              obscureText: true,
              decoration: InputDecoration(
                hintText: 'Repeat new password',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              ),
            ),

            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _profileSaving ? null : _saveProfile,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF007AFF),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: _profileSaving
                    ? const CircularProgressIndicator(color: Colors.white)
                    : const Text('Save Changes', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () async {
                await ApiService.signOut();
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
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _buildTabBar() {
    final tabs = [
      {'icon': Icons.assignment, 'label': 'Submit'},
      {'icon': Icons.history, 'label': 'History'},
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
              onTap: () => setState(() => _activeTab = i),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(tabs[i]['icon'] as IconData,
                      color: active ? const Color(0xFF007AFF) : Colors.grey,
                      size: 22),
                  Text(tabs[i]['label'] as String,
                      style: TextStyle(
                          fontSize: 11,
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

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 4),
        child: Text(text,
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF333333))),
      );

  Widget _ctrl(String hint, TextEditingController ctrl) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: TextField(
          controller: ctrl,
          decoration: InputDecoration(
            hintText: hint,
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Color(0xFFe0e0e0))),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Color(0xFFe0e0e0))),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          ),
        ),
      );

  Widget _nextButton(String label, VoidCallback onPressed) => SizedBox(
        width: double.infinity,
        height: 52,
        child: ElevatedButton(
          onPressed: onPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF007AFF),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: Text(label,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        ),
      );

  Widget _navButtons(
          {required VoidCallback onBack,
          required VoidCallback onNext,
          required String nextLabel}) =>
      Row(children: [
        Expanded(
          child: OutlinedButton(
            onPressed: onBack,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 48),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('← Back'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: ElevatedButton(
            onPressed: onNext,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF007AFF),
              foregroundColor: Colors.white,
              minimumSize: const Size(0, 48),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: Text(nextLabel,
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
        ),
      ]);
}
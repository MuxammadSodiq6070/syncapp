import 'package:flutter/material.dart';

import '../ui/glass.dart';
import '../ui/theme.dart';
import 'localization.dart';

class Country {
  final String name;
  final String nativeName;
  final String code;
  final String dialCode;
  final String flag;

  const Country({
    required this.name,
    required this.nativeName,
    required this.code,
    required this.dialCode,
    required this.flag,
  });

  String get displayName => nativeName.isNotEmpty && nativeName != name ? '$name ($nativeName)' : name;
}

const List<Country> allCountries = [
  Country(name: 'Uzbekistan', nativeName: 'O‘zbekiston', code: 'UZ', dialCode: '+998', flag: '🇺🇿'),
  Country(name: 'Russia', nativeName: 'Россия', code: 'RU', dialCode: '+7', flag: '🇷🇺'),
  Country(name: 'Kazakhstan', nativeName: 'Қазақстан', code: 'KZ', dialCode: '+7', flag: '🇰🇿'),
  Country(name: 'Kyrgyzstan', nativeName: 'Кыргызстан', code: 'KG', dialCode: '+996', flag: '🇰🇬'),
  Country(name: 'Tajikistan', nativeName: 'Тоҷикистон', code: 'TJ', dialCode: '+992', flag: '🇹🇯'),
  Country(name: 'Turkmenistan', nativeName: 'Türkmenistan', code: 'TM', dialCode: '+993', flag: '🇹🇲'),
  Country(name: 'Azerbaijan', nativeName: 'Azərbaycan', code: 'AZ', dialCode: '+994', flag: '🇦🇿'),
  Country(name: 'Turkey', nativeName: 'Türkiye', code: 'TR', dialCode: '+90', flag: '🇹🇷'),
  Country(name: 'United States', nativeName: 'United States', code: 'US', dialCode: '+1', flag: '🇺🇸'),
  Country(name: 'United Kingdom', nativeName: 'United Kingdom', code: 'GB', dialCode: '+44', flag: '🇬🇧'),
  Country(name: 'Germany', nativeName: 'Deutschland', code: 'DE', dialCode: '+49', flag: '🇩🇪'),
  Country(
    name: 'United Arab Emirates',
    nativeName: 'الإمارات العربية المتحدة',
    code: 'AE',
    dialCode: '+971',
    flag: '🇦🇪',
  ),
  Country(name: 'Saudi Arabia', nativeName: 'المملكة العربية السعودية', code: 'SA', dialCode: '+966', flag: '🇸🇦'),
  Country(name: 'South Korea', nativeName: '대한민국', code: 'KR', dialCode: '+82', flag: '🇰🇷'),
  Country(name: 'China', nativeName: '中国', code: 'CN', dialCode: '+86', flag: '🇨🇳'),
  Country(name: 'India', nativeName: 'भारत', code: 'IN', dialCode: '+91', flag: '🇮🇳'),
  Country(name: 'Ukraine', nativeName: 'Україна', code: 'UA', dialCode: '+380', flag: '🇺🇦'),
  Country(name: 'Belarus', nativeName: 'Беларусь', code: 'BY', dialCode: '+375', flag: '🇧🇾'),
  Country(name: 'Canada', nativeName: 'Canada', code: 'CA', dialCode: '+1', flag: '🇨🇦'),
  Country(name: 'France', nativeName: 'France', code: 'FR', dialCode: '+33', flag: '🇫🇷'),
  Country(name: 'Italy', nativeName: 'Italia', code: 'IT', dialCode: '+39', flag: '🇮🇹'),
  Country(name: 'Spain', nativeName: 'España', code: 'ES', dialCode: '+34', flag: '🇪🇸'),
  Country(name: 'Poland', nativeName: 'Polska', code: 'PL', dialCode: '+48', flag: '🇵🇱'),
  Country(name: 'Japan', nativeName: '日本', code: 'JP', dialCode: '+81', flag: '🇯🇵'),
  Country(name: 'Egypt', nativeName: 'مصر', code: 'EG', dialCode: '+20', flag: '🇪🇬'),
  Country(name: 'Pakistan', nativeName: 'Pakistan', code: 'PK', dialCode: '+92', flag: '🇵🇰'),
  Country(name: 'Indonesia', nativeName: 'Indonesia', code: 'ID', dialCode: '+62', flag: '🇮🇩'),
  Country(name: 'Malaysia', nativeName: 'Malaysia', code: 'MY', dialCode: '+60', flag: '🇲🇾'),
  Country(name: 'Singapore', nativeName: 'Singapore', code: 'SG', dialCode: '+65', flag: '🇸🇬'),
  Country(name: 'Brazil', nativeName: 'Brasil', code: 'BR', dialCode: '+55', flag: '🇧🇷'),
  Country(name: 'Afghanistan', nativeName: 'افغانستان', code: 'AF', dialCode: '+93', flag: '🇦🇫'),
  Country(name: 'Albania', nativeName: 'Shqipëria', code: 'AL', dialCode: '+355', flag: '🇦🇱'),
  Country(name: 'Algeria', nativeName: 'الجزائر', code: 'DZ', dialCode: '+213', flag: '🇩🇿'),
  Country(name: 'Andorra', nativeName: 'Andorra', code: 'AD', dialCode: '+376', flag: '🇦🇩'),
  Country(name: 'Angola', nativeName: 'Angola', code: 'AO', dialCode: '+244', flag: '🇦🇴'),
  Country(name: 'Argentina', nativeName: 'Argentina', code: 'AR', dialCode: '+54', flag: '🇦🇷'),
  Country(name: 'Armenia', nativeName: 'Հայաստան', code: 'AM', dialCode: '+374', flag: '🇦🇲'),
  Country(name: 'Australia', nativeName: 'Australia', code: 'AU', dialCode: '+61', flag: '🇦🇺'),
  Country(name: 'Austria', nativeName: 'Österreich', code: 'AT', dialCode: '+43', flag: '🇦🇹'),
  Country(name: 'Bahamas', nativeName: 'Bahamas', code: 'BS', dialCode: '+1242', flag: '🇧🇸'),
  Country(name: 'Bahrain', nativeName: 'البحرين', code: 'BH', dialCode: '+973', flag: '🇧🇭'),
  Country(name: 'Bangladesh', nativeName: 'বাংলাদেশ', code: 'BD', dialCode: '+880', flag: '🇧🇩'),
  Country(name: 'Barbados', nativeName: 'Barbados', code: 'BB', dialCode: '+1246', flag: '🇧🇧'),
  Country(name: 'Belgium', nativeName: 'België', code: 'BE', dialCode: '+32', flag: '🇧🇪'),
  Country(name: 'Belize', nativeName: 'Belize', code: 'BZ', dialCode: '+501', flag: '🇧🇿'),
  Country(name: 'Benin', nativeName: 'Bénin', code: 'BJ', dialCode: '+229', flag: '🇧🇯'),
  Country(name: 'Bhutan', nativeName: 'འབྲུག', code: 'BT', dialCode: '+975', flag: '🇧🇹'),
  Country(name: 'Bolivia', nativeName: 'Bolivia', code: 'BO', dialCode: '+591', flag: '🇧🇴'),
  Country(
    name: 'Bosnia and Herzegovina',
    nativeName: 'Bosna i Hercegovina',
    code: 'BA',
    dialCode: '+387',
    flag: '🇧🇦',
  ),
  Country(name: 'Botswana', nativeName: 'Botswana', code: 'BW', dialCode: '+267', flag: '🇧🇼'),
  Country(name: 'Brunei', nativeName: 'Brunei', code: 'BN', dialCode: '+673', flag: '🇧🇳'),
  Country(name: 'Bulgaria', nativeName: 'България', code: 'BG', dialCode: '+359', flag: '🇧🇬'),
  Country(name: 'Burkina Faso', nativeName: 'Burkina Faso', code: 'BF', dialCode: '+226', flag: '🇧🇫'),
  Country(name: 'Burundi', nativeName: 'Burundi', code: 'BI', dialCode: '+257', flag: '🇧🇮'),
  Country(name: 'Cambodia', nativeName: 'កម្ពុជា', code: 'KH', dialCode: '+855', flag: '🇰🇭'),
  Country(name: 'Cameroon', nativeName: 'Cameroun', code: 'CM', dialCode: '+237', flag: '🇨🇲'),
  Country(name: 'Cape Verde', nativeName: 'Cabo Verde', code: 'CV', dialCode: '+238', flag: '🇨🇻'),
  Country(name: 'Central African Republic', nativeName: 'Centrafrique', code: 'CF', dialCode: '+236', flag: '🇨🇫'),
  Country(name: 'Chad', nativeName: 'Tchad', code: 'TD', dialCode: '+235', flag: '🇹🇩'),
  Country(name: 'Chile', nativeName: 'Chile', code: 'CL', dialCode: '+56', flag: '🇨🇱'),
  Country(name: 'Colombia', nativeName: 'Colombia', code: 'CO', dialCode: '+57', flag: '🇨🇴'),
  Country(name: 'Comoros', nativeName: 'جزر القمر', code: 'KM', dialCode: '+269', flag: '🇰🇲'),
  Country(name: 'Congo', nativeName: 'Congo', code: 'CG', dialCode: '+242', flag: '🇨🇬'),
  Country(name: 'Costa Rica', nativeName: 'Costa Rica', code: 'CR', dialCode: '+506', flag: '🇨🇷'),
  Country(name: 'Croatia', nativeName: 'Hrvatska', code: 'HR', dialCode: '+385', flag: '🇭🇷'),
  Country(name: 'Cuba', nativeName: 'Cuba', code: 'CU', dialCode: '+53', flag: '🇨🇺'),
  Country(name: 'Cyprus', nativeName: 'Κύπρος', code: 'CY', dialCode: '+357', flag: '🇨🇾'),
  Country(name: 'Czech Republic', nativeName: 'Česká republika', code: 'CZ', dialCode: '+420', flag: '🇨🇿'),
  Country(name: 'Denmark', nativeName: 'Danmark', code: 'DK', dialCode: '+45', flag: '🇩🇰'),
  Country(name: 'Djibouti', nativeName: 'جيبوتي', code: 'DJ', dialCode: '+253', flag: '🇩🇯'),
  Country(name: 'Dominican Republic', nativeName: 'República Dominicana', code: 'DO', dialCode: '+1809', flag: '🇩🇴'),
  Country(name: 'Ecuador', nativeName: 'Ecuador', code: 'EC', dialCode: '+593', flag: '🇪🇨'),
  Country(name: 'El Salvador', nativeName: 'El Salvador', code: 'SV', dialCode: '+503', flag: '🇸🇻'),
  Country(name: 'Equatorial Guinea', nativeName: 'Guinea Ecuatorial', code: 'GQ', dialCode: '+240', flag: '🇬🇶'),
  Country(name: 'Eritrea', nativeName: 'ኤርትራ', code: 'ER', dialCode: '+291', flag: '🇪🇷'),
  Country(name: 'Estonia', nativeName: 'Eesti', code: 'EE', dialCode: '+372', flag: '🇪🇪'),
  Country(name: 'Ethiopia', nativeName: 'ኢትዮጵያ', code: 'ET', dialCode: '+251', flag: '🇪🇹'),
  Country(name: 'Fiji', nativeName: 'Fiji', code: 'FJ', dialCode: '+679', flag: '🇫🇯'),
  Country(name: 'Finland', nativeName: 'Suomi', code: 'FI', dialCode: '+358', flag: '🇫🇮'),
  Country(name: 'Gabon', nativeName: 'Gabon', code: 'GA', dialCode: '+241', flag: '🇬🇦'),
  Country(name: 'Gambia', nativeName: 'Gambia', code: 'GM', dialCode: '+220', flag: '🇬🇲'),
  Country(name: 'Georgia', nativeName: 'საქართველო', code: 'GE', dialCode: '+995', flag: '🇬🇪'),
  Country(name: 'Ghana', nativeName: 'Ghana', code: 'GH', dialCode: '+233', flag: '🇬🇭'),
  Country(name: 'Greece', nativeName: 'Ελλάδα', code: 'GR', dialCode: '+30', flag: '🇬🇷'),
  Country(name: 'Guatemala', nativeName: 'Guatemala', code: 'GT', dialCode: '+502', flag: '🇬🇹'),
  Country(name: 'Guinea', nativeName: 'Guinée', code: 'GN', dialCode: '+224', flag: '🇬🇳'),
  Country(name: 'Guyana', nativeName: 'Guyana', code: 'GY', dialCode: '+592', flag: '🇬🇾'),
  Country(name: 'Haiti', nativeName: 'Haïti', code: 'HT', dialCode: '+509', flag: '🇭🇹'),
  Country(name: 'Honduras', nativeName: 'Honduras', code: 'HN', dialCode: '+504', flag: '🇭🇳'),
  Country(name: 'Hong Kong', nativeName: '香港', code: 'HK', dialCode: '+852', flag: '🇭🇰'),
  Country(name: 'Hungary', nativeName: 'Magyarország', code: 'HU', dialCode: '+36', flag: '🇭🇺'),
  Country(name: 'Iceland', nativeName: 'Ísland', code: 'IS', dialCode: '+354', flag: '🇮🇸'),
  Country(name: 'Iran', nativeName: 'ایران', code: 'IR', dialCode: '+98', flag: '🇮🇷'),
  Country(name: 'Iraq', nativeName: 'العراق', code: 'IQ', dialCode: '+964', flag: '🇮🇶'),
  Country(name: 'Ireland', nativeName: 'Éire', code: 'IE', dialCode: '+353', flag: '🇮🇪'),
  Country(name: 'Israel', nativeName: 'ישראל', code: 'IL', dialCode: '+972', flag: '🇮🇱'),
  Country(name: 'Ivory Coast', nativeName: 'Côte d\'Ivoire', code: 'CI', dialCode: '+225', flag: '🇨🇮'),
  Country(name: 'Jamaica', nativeName: 'Jamaica', code: 'JM', dialCode: '+1876', flag: '🇯🇲'),
  Country(name: 'Jordan', nativeName: 'الأردن', code: 'JO', dialCode: '+962', flag: '🇯🇴'),
  Country(name: 'Kenya', nativeName: 'Kenya', code: 'KE', dialCode: '+254', flag: '🇰🇪'),
  Country(name: 'Kuwait', nativeName: 'الكويت', code: 'KW', dialCode: '+965', flag: '🇰🇼'),
  Country(name: 'Laos', nativeName: 'ປະເທດລາວ', code: 'LA', dialCode: '+856', flag: '🇱🇦'),
  Country(name: 'Latvia', nativeName: 'Latvija', code: 'LV', dialCode: '+371', flag: '🇱🇻'),
  Country(name: 'Lebanon', nativeName: 'لبنان', code: 'LB', dialCode: '+961', flag: '🇱🇧'),
  Country(name: 'Libya', nativeName: 'ليبيا', code: 'LY', dialCode: '+218', flag: '🇱🇾'),
  Country(name: 'Liechtenstein', nativeName: 'Liechtenstein', code: 'LI', dialCode: '+423', flag: '🇱🇮'),
  Country(name: 'Lithuania', nativeName: 'Lietuva', code: 'LT', dialCode: '+370', flag: '🇱🇹'),
  Country(name: 'Luxembourg', nativeName: 'Luxembourg', code: 'LU', dialCode: '+352', flag: '🇱🇺'),
  Country(name: 'Macau', nativeName: '澳門', code: 'MO', dialCode: '+853', flag: '🇲🇴'),
  Country(name: 'Madagascar', nativeName: 'Madagasikara', code: 'MG', dialCode: '+261', flag: '🇲🇬'),
  Country(name: 'Malawi', nativeName: 'Malawi', code: 'MW', dialCode: '+265', flag: '🇲🇼'),
  Country(name: 'Maldives', nativeName: 'ދިވެހިރާއްޖެ', code: 'MV', dialCode: '+960', flag: '🇲🇻'),
  Country(name: 'Mali', nativeName: 'Mali', code: 'ML', dialCode: '+223', flag: '🇲🇱'),
  Country(name: 'Malta', nativeName: 'Malta', code: 'MT', dialCode: '+356', flag: '🇲🇹'),
  Country(name: 'Mauritania', nativeName: 'موريتانيا', code: 'MR', dialCode: '+222', flag: '🇲🇷'),
  Country(name: 'Mauritius', nativeName: 'Maurice', code: 'MU', dialCode: '+230', flag: '🇲🇺'),
  Country(name: 'Mexico', nativeName: 'México', code: 'MX', dialCode: '+52', flag: '🇲🇽'),
  Country(name: 'Moldova', nativeName: 'Moldova', code: 'MD', dialCode: '+373', flag: '🇲🇩'),
  Country(name: 'Monaco', nativeName: 'Monaco', code: 'MC', dialCode: '+377', flag: '🇲🇨'),
  Country(name: 'Mongolia', nativeName: 'Монгол', code: 'MN', dialCode: '+976', flag: '🇲🇳'),
  Country(name: 'Montenegro', nativeName: 'Crna Gora', code: 'ME', dialCode: '+382', flag: '🇲🇪'),
  Country(name: 'Morocco', nativeName: 'المغرب', code: 'MA', dialCode: '+212', flag: '🇲🇦'),
  Country(name: 'Mozambique', nativeName: 'Moçambique', code: 'MZ', dialCode: '+258', flag: '🇲🇿'),
  Country(name: 'Myanmar', nativeName: 'မြန်မာ', code: 'MM', dialCode: '+95', flag: '🇲🇲'),
  Country(name: 'Namibia', nativeName: 'Namibia', code: 'NA', dialCode: '+264', flag: '🇳🇦'),
  Country(name: 'Nepal', nativeName: 'नेपाल', code: 'NP', dialCode: '+977', flag: '🇳🇵'),
  Country(name: 'Netherlands', nativeName: 'Nederland', code: 'NL', dialCode: '+31', flag: '🇳🇱'),
  Country(name: 'New Zealand', nativeName: 'New Zealand', code: 'NZ', dialCode: '+64', flag: '🇳🇿'),
  Country(name: 'Nicaragua', nativeName: 'Nicaragua', code: 'NI', dialCode: '+505', flag: '🇳🇮'),
  Country(name: 'Niger', nativeName: 'Niger', code: 'NE', dialCode: '+227', flag: '🇳🇪'),
  Country(name: 'Nigeria', nativeName: 'Nigeria', code: 'NG', dialCode: '+234', flag: '🇳🇬'),
  Country(name: 'North Macedonia', nativeName: 'Северна Македонија', code: 'MK', dialCode: '+389', flag: '🇲🇰'),
  Country(name: 'Norway', nativeName: 'Norge', code: 'NO', dialCode: '+47', flag: '🇳🇴'),
  Country(name: 'Oman', nativeName: 'عُمان', code: 'OM', dialCode: '+968', flag: '🇴🇲'),
  Country(name: 'Panama', nativeName: 'Panamá', code: 'PA', dialCode: '+507', flag: '🇵🇦'),
  Country(name: 'Papua New Guinea', nativeName: 'Papua New Guinea', code: 'PG', dialCode: '+675', flag: '🇵🇬'),
  Country(name: 'Paraguay', nativeName: 'Paraguay', code: 'PY', dialCode: '+595', flag: '🇵🇾'),
  Country(name: 'Peru', nativeName: 'Perú', code: 'PE', dialCode: '+51', flag: '🇵🇪'),
  Country(name: 'Philippines', nativeName: 'Pilipinas', code: 'PH', dialCode: '+63', flag: '🇵🇭'),
  Country(name: 'Portugal', nativeName: 'Portugal', code: 'PT', dialCode: '+351', flag: '🇵🇹'),
  Country(name: 'Qatar', nativeName: 'قطر', code: 'QA', dialCode: '+974', flag: '🇶🇦'),
  Country(name: 'Romania', nativeName: 'România', code: 'RO', dialCode: '+40', flag: '🇷🇴'),
  Country(name: 'Rwanda', nativeName: 'Rwanda', code: 'RW', dialCode: '+250', flag: '🇷🇼'),
  Country(name: 'Senegal', nativeName: 'Sénégal', code: 'SN', dialCode: '+221', flag: '🇸🇳'),
  Country(name: 'Serbia', nativeName: 'Србија', code: 'RS', dialCode: '+381', flag: '🇷🇸'),
  Country(name: 'Slovakia', nativeName: 'Slovensko', code: 'SK', dialCode: '+421', flag: '🇸🇰'),
  Country(name: 'Slovenia', nativeName: 'Slovenija', code: 'SI', dialCode: '+386', flag: '🇸🇮'),
  Country(name: 'Somalia', nativeName: 'Soomaaliya', code: 'SO', dialCode: '+252', flag: '🇸🇴'),
  Country(name: 'South Africa', nativeName: 'South Africa', code: 'ZA', dialCode: '+27', flag: '🇿🇦'),
  Country(name: 'Sri Lanka', nativeName: 'ශ්‍රී ලංකාව', code: 'LK', dialCode: '+94', flag: '🇱🇰'),
  Country(name: 'Sudan', nativeName: 'السودان', code: 'SD', dialCode: '+249', flag: '🇸🇩'),
  Country(name: 'Sweden', nativeName: 'Sverige', code: 'SE', dialCode: '+46', flag: '🇸🇪'),
  Country(name: 'Switzerland', nativeName: 'Schweiz', code: 'CH', dialCode: '+41', flag: '🇨🇭'),
  Country(name: 'Syria', nativeName: 'سوريا', code: 'SY', dialCode: '+963', flag: '🇸🇾'),
  Country(name: 'Taiwan', nativeName: '台灣', code: 'TW', dialCode: '+886', flag: '🇹🇼'),
  Country(name: 'Tanzania', nativeName: 'Tanzania', code: 'TZ', dialCode: '+255', flag: '🇹🇿'),
  Country(name: 'Thailand', nativeName: 'ประเทศไทย', code: 'TH', dialCode: '+66', flag: '🇹🇭'),
  Country(name: 'Tunisia', nativeName: 'تونس', code: 'TN', dialCode: '+216', flag: '🇹🇳'),
  Country(name: 'Uganda', nativeName: 'Uganda', code: 'UG', dialCode: '+256', flag: '🇺🇬'),
  Country(name: 'Uruguay', nativeName: 'Uruguay', code: 'UY', dialCode: '+598', flag: '🇺🇾'),
  Country(name: 'Venezuela', nativeName: 'Venezuela', code: 'VE', dialCode: '+58', flag: '🇻🇪'),
  Country(name: 'Vietnam', nativeName: 'Việt Nam', code: 'VN', dialCode: '+84', flag: '🇻🇳'),
  Country(name: 'Yemen', nativeName: 'اليمن', code: 'YE', dialCode: '+967', flag: '🇾🇪'),
  Country(name: 'Zambia', nativeName: 'Zambia', code: 'ZM', dialCode: '+260', flag: '🇿🇲'),
  Country(name: 'Zimbabwe', nativeName: 'Zimbabwe', code: 'ZW', dialCode: '+263', flag: '🇿🇼'),
];

Country defaultCountry([Locale? locale]) {
  if (locale != null && locale.countryCode != null) {
    final c = findCountryByCode(locale.countryCode!);
    if (c != null) return c;
  }
  return allCountries.first; // Uzbekistan
}

Country? findCountryByCode(String code) {
  final upper = code.toUpperCase();
  for (final c in allCountries) {
    if (c.code == upper) return c;
  }
  return null;
}

Country? findCountryByDialCode(String dial) {
  var clean = dial.trim();
  if (!clean.startsWith('+')) clean = '+$clean';
  Country? best;
  int bestLen = 0;
  for (final c in allCountries) {
    if (clean.startsWith(c.dialCode) && c.dialCode.length > bestLen) {
      best = c;
      bestLen = c.dialCode.length;
    }
  }
  return best;
}

/// Telegram-style country picker modal bottom sheet
Future<Country?> showCountryPicker(BuildContext context, {Country? current}) {
  return showModalBottomSheet<Country>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) => _CountryPickerSheet(current: current),
  );
}

class _CountryPickerSheet extends StatefulWidget {
  const _CountryPickerSheet({this.current});
  final Country? current;

  @override
  State<_CountryPickerSheet> createState() => _CountryPickerSheetState();
}

class _CountryPickerSheetState extends State<_CountryPickerSheet> {
  final _search = TextEditingController();
  List<Country> _filtered = allCountries;

  @override
  void initState() {
    super.initState();
    _search.addListener(_onSearch);
  }

  @override
  void dispose() {
    _search.removeListener(_onSearch);
    _search.dispose();
    super.dispose();
  }

  void _onSearch() {
    final q = _search.text.trim().toLowerCase();
    setState(() {
      if (q.isEmpty) {
        _filtered = allCountries;
      } else {
        _filtered = allCountries.where((c) {
          return c.name.toLowerCase().contains(q) ||
              c.nativeName.toLowerCase().contains(q) ||
              c.code.toLowerCase().contains(q) ||
              c.dialCode.contains(q);
        }).toList();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Container(
      height: media.size.height * 0.82,
      decoration: BoxDecoration(
        color: const Color(0xFF161A22).withValues(alpha: 0.95),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.6), blurRadius: 30, spreadRadius: 10)],
      ),
      child: Column(
        children: [
          const SizedBox(height: 12),
          // Drag handle
          Container(
            width: 44,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Expanded(child: Text(tr('select_country'), style: SyncText.headline.copyWith(fontSize: 18))),
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.white70),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: GlassField(
              controller: _search,
              hint: tr('search_country'),
              leading: const Icon(Icons.search_rounded, color: Colors.white70),
            ),
          ),
          Expanded(
            child: _filtered.isEmpty
                ? Center(child: Text(tr('no_results'), style: SyncText.secondary))
                : ListView.builder(
                    itemCount: _filtered.length,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    itemBuilder: (ctx, i) {
                      final c = _filtered[i];
                      final isSelected = widget.current?.code == c.code;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: PressScale(
                          onTap: () => Navigator.pop(context, c),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? SyncColors.accent.withValues(alpha: 0.25)
                                  : Colors.white.withValues(alpha: 0.04),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: isSelected
                                    ? SyncColors.accent.withValues(alpha: 0.6)
                                    : Colors.white.withValues(alpha: 0.06),
                              ),
                            ),
                            child: Row(
                              children: [
                                Text(c.flag, style: const TextStyle(fontSize: 24)),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        c.name,
                                        style: SyncText.body.copyWith(
                                          fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                                        ),
                                      ),
                                      if (c.nativeName != c.name && c.nativeName.isNotEmpty)
                                        Text(c.nativeName, style: SyncText.caption.copyWith(color: Colors.white54)),
                                    ],
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: SyncColors.accent.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    c.dialCode,
                                    style: const TextStyle(
                                      fontFamily: syncFont,
                                      color: SyncColors.accentBright,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 14,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

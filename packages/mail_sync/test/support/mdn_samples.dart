// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Read receipts (RFC 8098 reports) as real mail apps send them, for
// Maria's sent mail. Addresses use reserved test domains.

/// Gmail (Google Workspace): thread headers and Original-Message-ID.
const gmailReceipt = '''
Return-Path: <ana@northwind.example>
From: Ana Silva <ana@northwind.example>
To: Maria Lopez <maria@citusmail.test>
Subject: Read: Quarterly plans
Date: Fri, 6 Nov 2026 15:42:10 +0000
Message-ID: <CAJx3kq9vQ0n=4fM1dNtd5Q@mail.gmail.com>
In-Reply-To: <plans-1@citusmail.test>
References: <plans-1@citusmail.test>
MIME-Version: 1.0
Content-Type: multipart/report; report-type=disposition-notification;
 boundary="000000000000a1b2c3d4e5f6"

--000000000000a1b2c3d4e5f6
Content-Type: text/plain; charset="UTF-8"

This is a receipt for the mail you sent to
ana@northwind.example at 11/6/2026, 2:10 PM

This receipt verifies that the message has been displayed on the recipient's computer at 11/6/2026, 3:42 PM

--000000000000a1b2c3d4e5f6
Content-Type: message/disposition-notification

Reporting-UA: mail.google.com; Gmail
Final-Recipient: rfc822; ana@northwind.example
Original-Message-ID: <plans-1@citusmail.test>
Disposition: manual-action/MDN-sent-manually; displayed

--000000000000a1b2c3d4e5f6--
''';

/// Outlook / Exchange: "Read: (subject)", no thread headers, so only the
/// Original-Message-ID in the report names the message.
const outlookReceipt = '''
From: Ben Okafor <ben@contoso.example>
To: Maria Lopez <maria@citusmail.test>
Subject: Read: Quarterly plans
Thread-Topic: Quarterly plans
Thread-Index: AQHZ4kQ1b2c3d4e5f6a7b8c9d0e1f2a3
Date: Fri, 6 Nov 2026 16:05:31 +0000
Message-ID: <AM0PR10MB31234A1B2C3D4E5F6@AM0PR10MB3123.EURPRD10.PROD.OUTLOOK.COM>
Content-Language: en-GB
X-MS-Has-Attach:
X-MS-TNEF-Correlator:
Content-Type: multipart/report; report-type=disposition-notification;
\tboundary="_000_AM0PR10MB31234A1B2C3D4E5F6_"
MIME-Version: 1.0

--_000_AM0PR10MB31234A1B2C3D4E5F6_
Content-Type: text/plain; charset="us-ascii"
Content-Transfer-Encoding: quoted-printable

Your message

To: Ben Okafor
Subject: Quarterly plans
Sent: Friday, November 6, 2026 2:10:04 PM (UTC+00:00) Dublin, Edinburgh, =
Lisbon, London

was read on Friday, November 6, 2026 4:05:22 PM (UTC+00:00) Dublin, Edinbu=
rgh, Lisbon, London.

--_000_AM0PR10MB31234A1B2C3D4E5F6_
Content-Type: message/disposition-notification

Reporting-UA: AM0PR10MB3123.EURPRD10.PROD.OUTLOOK.COM; Microsoft Exchange Server
Final-recipient: RFC822; ben@contoso.example
Disposition: automatic-action/MDN-sent-automatically; displayed
X-MSExch-Correlation-Key: 2b3c4d5e6f7a8b9c
Original-Message-ID: <plans-1@citusmail.test>
X-Display-Name: Ben Okafor

--_000_AM0PR10MB31234A1B2C3D4E5F6_--
''';

/// Thunderbird: "Return Receipt (displayed) - (subject)", with the
/// original's headers as a third part. [kind] is the disposition.
String thunderbirdReceipt({
  String kind = 'displayed',
  String original = 'trip-2@citusmail.test',
  String subject = 'Trip to Lisbon',
}) =>
    '''
From: Chloe Martin <chloe@fastmail.example>
Subject: Return Receipt ($kind) - $subject
To: maria@citusmail.test
Date: Sat, 7 Nov 2026 09:12:44 +0100
Message-ID: <5f1c2a3b-9d8e-4f7a-$kind@fastmail.example>
In-Reply-To: <$original>
References: <earlier-0@citusmail.test> <$original>
User-Agent: Mozilla Thunderbird
MIME-Version: 1.0
Content-Type: multipart/report; report-type=disposition-notification;
 boundary="------------A1B2C3D4E5F6A7B8C9D0E1F2"

This is a multi-part message in MIME format.
--------------A1B2C3D4E5F6A7B8C9D0E1F2
Content-Type: text/plain; charset=UTF-8
Content-Transfer-Encoding: 7bit

This is a Return Receipt for the mail that you sent to <chloe@fastmail.example>.

Note: This Return Receipt only acknowledges that the message was displayed on the recipient's computer. There is no guarantee that the recipient has read or understood the message contents.

--------------A1B2C3D4E5F6A7B8C9D0E1F2
Content-Type: message/disposition-notification; name="MDNPart2.txt"
Content-Disposition: inline
Content-Transfer-Encoding: 7bit

Reporting-UA: fastmail.example; Mozilla Thunderbird
Final-Recipient: rfc822;chloe@fastmail.example
Original-Message-ID: <$original>
Disposition: manual-action/MDN-sent-manually; $kind

--------------A1B2C3D4E5F6A7B8C9D0E1F2
Content-Type: text/rfc822-headers; name="MDNPart3.txt"
Content-Disposition: inline
Content-Transfer-Encoding: 7bit

Date: Fri, 6 Nov 2026 18:30:00 +0100
From: Maria Lopez <maria@citusmail.test>
To: Chloe Martin <chloe@fastmail.example>
Subject: $subject
Message-ID: <$original>

--------------A1B2C3D4E5F6A7B8C9D0E1F2--
''';

/// A mobile app's receipt without Original-Message-ID: only References
/// names the message.
const referencesOnlyReceipt = '''
From: Dev Patel <dev@mobile.example>
To: maria@citusmail.test
Subject: Read: Quarterly plans
Date: Fri, 6 Nov 2026 17:20:00 +0000
Message-ID: <mdn.20261106172000.dev@mobile.example>
References: <plans-1@citusmail.test>
MIME-Version: 1.0
Content-Type: multipart/report; report-type="disposition-notification";
 boundary="mdn-part"

--mdn-part
Content-Type: text/plain; charset=utf-8

Your message "Quarterly plans" was displayed.

--mdn-part
Content-Type: message/disposition-notification

Reporting-UA: Mobile Mail
Final-Recipient: rfc822;dev@mobile.example
Disposition: manual-action/MDN-sent-manually; displayed

--mdn-part--
''';

/// An ordinary email whose subject starts with "Read:": not a receipt.
const readColonEmail = '''
From: Lena Fischer <lena@bookclub.example>
To: maria@citusmail.test
Subject: Read: The Midnight Library - notes for Thursday
Date: Fri, 6 Nov 2026 12:00:00 +0000
Message-ID: <notes-77@bookclub.example>
In-Reply-To: <plans-1@citusmail.test>
MIME-Version: 1.0
Content-Type: text/plain; charset=utf-8

Hi all, here are my notes for Thursday. Read: chapters 1-12.
''';

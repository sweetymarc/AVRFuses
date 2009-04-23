#import "AVRFusesController.h"

#import <termios.h>

#import <CoreFoundation/CoreFoundation.h>

#import <IOKit/IOKitLib.h>
#import <IOKit/serial/IOSerialKeys.h>
#import <IOKit/IOBSD.h>

/*
Need to come up with just a few  generic methods:
readMemory, verifyMemory, programMemory and use it similar to how avrdude uses -U
*/

/*
TODO removed lockbits for now so I can release 1.4
This method of reading in the configs causes problems in all the other
methods (mainly read) because of the loop that looks at all fusenames
and expects a file. I don't like having to hardcode the fuse names in each
function.

Also, right now it's fine cause we never add lockbits fusename to fuses, but if we do (like
I originally intended) then everything that uses the fuses array needs to change. Should store lockbits
seperately or come up with a more generic method of read/writing/verifying/displaying memory.
*/

@implementation AVRFusesController

- (void)awakeFromNib
{
	parts = [[NSMutableDictionary alloc] init];
	selectedPart = nil;
	fuses = [[NSMutableDictionary alloc] init];
	fuseSettings = [[NSMutableArray alloc] init];
	lockbitSettings = [[NSMutableArray alloc] init];

	[fusesTableView setDoubleAction: @selector(tableViewDoubleClick:)];
	[lockbitsTableView setDoubleAction: @selector(tableViewDoubleClick:)];
	
	[self loadPartDefinitions];

	NSArray *sortedPartNames = [[parts allKeys] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
	for (int i = 0; i < [sortedPartNames count]; i++) {
		NSString *partName = [sortedPartNames objectAtIndex: i];
		[devicePopUpButton addItemWithTitle: partName];
	}
	
	if ([[NSUserDefaults standardUserDefaults] stringForKey: @"lastSelectedPart"] != nil) {
		[devicePopUpButton selectItemWithTitle: [[NSUserDefaults standardUserDefaults] stringForKey: @"lastSelectedPart"]];
	}
	
	[avrdudeSerialBaudPopUpButton removeAllItems];
	[avrdudeSerialBaudPopUpButton addItemWithTitle: @"[Default]"];
	[avrdudeSerialBaudPopUpButton addItemWithTitle: @"300"];
	[avrdudeSerialBaudPopUpButton addItemWithTitle: @"1200"];
	[avrdudeSerialBaudPopUpButton addItemWithTitle: @"2400"];
	[avrdudeSerialBaudPopUpButton addItemWithTitle: @"4800"];
	[avrdudeSerialBaudPopUpButton addItemWithTitle: @"9600"];
	[avrdudeSerialBaudPopUpButton addItemWithTitle: @"19200"];
	[avrdudeSerialBaudPopUpButton addItemWithTitle: @"38400"];
	[avrdudeSerialBaudPopUpButton addItemWithTitle: @"57600"];
	[avrdudeSerialBaudPopUpButton addItemWithTitle: @"115200"];
	
	if ([[NSUserDefaults standardUserDefaults] stringForKey: @"avrdudeSerialBaud"] != nil) {
		[avrdudeSerialBaudPopUpButton selectItemWithTitle: [[NSUserDefaults standardUserDefaults] stringForKey: @"avrdudeSerialBaud"]];
	}
	
	[avrdudePortPopUpButton removeAllItems];
	[avrdudePortPopUpButton addItemWithObjectValue: @"usb"];
	NSMutableArray *serialPorts = [NSMutableArray array];
	[self addAllSerialPortsToArray: serialPorts];
	for (int i = 0; i < [serialPorts count]; i++) {
		[avrdudePortPopUpButton addItemWithObjectValue: [serialPorts objectAtIndex: i]];
	}
	
	/*
	if ([[NSUserDefaults standardUserDefaults] stringForKey: @"avrdudePort"] != nil) {
		[avrdudePortPopUpButton selectItemWithTitle: [[NSUserDefaults standardUserDefaults] stringForKey: @"avrdudePort"]];
	}
	*/
	
	[self deviceChanged: nil];
	
	[mainWindow makeKeyAndOrderFront: nil];
	
	//NSString *avrdudePort = [[NSUserDefaults standardUserDefaults] stringForKey: @"avrdudePort"];
	NSString *avrdudeConfig = [[NSUserDefaults standardUserDefaults] stringForKey: @"avrdudeConfig"];
	NSString *avrdudePath = [[NSUserDefaults standardUserDefaults] stringForKey: @"avrdudePath"];

	//if (!avrdudePort || !avrdudeConfig || !avrdudePath) {
	if (!avrdudeConfig || !avrdudePath) {
		[self showPrefs: nil];
	}
	else {
		[self loadAvrdudeConfigs];
	}
}

- (void)loadPartDefinitions
{
	NSBundle *thisBundle = [NSBundle mainBundle];
	char buffer[1000];
	FILE *file = fopen([[thisBundle pathForResource: @"AVRFuses" ofType: @"parts"] UTF8String], "r");
	while(fgets(buffer, 1000, file) != NULL) {
		NSString *line = [[NSString alloc] initWithCString: buffer];
		NSScanner *scanner = [NSScanner scannerWithString: line];

		NSString *settingPart = nil;
		NSString *settingFuse = nil;
		unsigned int settingMask = 0;
		unsigned int settingValue = 0;
		NSString *settingText = nil;
		
		[scanner scanUpToString: @"," intoString: &settingPart];
		[scanner setScanLocation:[scanner scanLocation] + 1];
		[scanner scanUpToString: @"," intoString: &settingFuse];
		[scanner setScanLocation:[scanner scanLocation] + 1];
		[scanner scanHexInt: &settingMask];
		[scanner setScanLocation:[scanner scanLocation] + 1];
		[scanner scanHexInt: &settingValue];
		[scanner setScanLocation:[scanner scanLocation] + 1];
		[scanner scanUpToString: @"\n" intoString: &settingText];
		
		// TODO see if this makes sense since we're adding to arrays and such
		[settingPart retain];
		[settingFuse retain];
		[settingText retain];
		
		PartDefinition *part = nil;
		if ([parts objectForKey: settingPart] == nil) {
			part = [[PartDefinition alloc] init];
			part->name = settingPart;
			[parts setObject: part forKey: part->name];
		}
		else {
			part = [parts objectForKey: settingPart];
		}
		
		FuseDefinition *fuse = nil;
		if ([settingFuse isEqualToString: @"LOCKBIT"]) {
			if (part->lockbits == nil) {
				fuse = [[FuseDefinition alloc] init];
				fuse->name = settingFuse;
				part->lockbits = fuse;
			}
			else {
				fuse = part->lockbits;
			}
		}
		else {
			if ([part->fuses objectForKey: settingFuse] == nil) {
				fuse = [[FuseDefinition alloc] init];
				fuse->name = settingFuse;
				[part->fuses setObject: fuse forKey: fuse->name];
			}
			else {
				fuse = [part->fuses objectForKey: settingFuse];
			}
		}
		FuseSetting *fuseSetting = [[FuseSetting alloc] init];
		fuseSetting->fuse = fuse->name;
		fuseSetting->mask = settingMask & 0xff;
		fuseSetting->value = settingValue & 0xff;
		fuseSetting->text = settingText;
		
		[fuse->settings addObject: fuseSetting];
	}
	fclose(file);
}


- (IBAction)deviceChanged:(id)sender
{
	selectedPart = [parts objectForKey: [[devicePopUpButton selectedItem] title]];
	
	[[NSUserDefaults standardUserDefaults] setObject: selectedPart->name forKey: @"lastSelectedPart"];
	
	[fuseSettings removeAllObjects];
	[lockbitSettings removeAllObjects];
	
	if ([selectedPart->fuses objectForKey:@"EXTENDED"] != nil) {
		FuseDefinition *fuse = [selectedPart->fuses objectForKey: @"EXTENDED"];
		for (int i = 0; i < [fuse->settings count]; i++) {
			[fuseSettings addObject: [fuse->settings objectAtIndex: i]];
		}
	}
	if ([selectedPart->fuses objectForKey:@"HIGH"] != nil) {
		FuseDefinition *fuse = [selectedPart->fuses objectForKey: @"HIGH"];
		for (int i = 0; i < [fuse->settings count]; i++) {
			[fuseSettings addObject: [fuse->settings objectAtIndex: i]];
		}
	}
	if ([selectedPart->fuses objectForKey:@"LOW"] != nil) {
		FuseDefinition *fuse = [selectedPart->fuses objectForKey: @"LOW"];
		for (int i = 0; i < [fuse->settings count]; i++) {
			[fuseSettings addObject: [fuse->settings objectAtIndex: i]];
		}
	}
	if (selectedPart->lockbits != nil) {
		FuseDefinition *fuse = selectedPart->lockbits;
		for (int i = 0; i < [fuse->settings count]; i++) {
			[lockbitSettings addObject: [fuse->settings objectAtIndex: i]];
		}
	}
	
	[fusesTableView reloadData];
	[lockbitsTableView reloadData];
	
	[fuses removeAllObjects];
	for (int i = 0; i < [[selectedPart->fuses allKeys] count]; i++) {
		[fuses setObject: [NSNumber numberWithUnsignedChar: 0xff] forKey: [[selectedPart->fuses allKeys] objectAtIndex: i]];
	}
}

- (IBAction)showPrefs:(id)sender
{
	[NSApp beginSheet:prefsWindow
		modalForWindow:mainWindow 
		modalDelegate:nil 
		didEndSelector:nil 
		contextInfo:nil];
	
	[self willChangeValueForKey: @"avrdudeAvailable"];
	[NSApp runModalForWindow:prefsWindow];
	[self didChangeValueForKey: @"avrdudeAvailable"];

    [NSApp endSheet:prefsWindow];
	
    [prefsWindow orderOut:self];	
	
	[self loadAvrdudeConfigs];
}

- (IBAction)closePrefs:(id)sender
{
	[NSApp stopModal];
}

- (IBAction)browseAvrdude:(id)sender
{
	NSOpenPanel *openPanel = [NSOpenPanel openPanel];
	[openPanel setCanChooseDirectories: NO];
	[openPanel setAllowsMultipleSelection: NO];
	[openPanel setMessage: @"Type / to browse to hidden directories."];
	if ([openPanel runModalForDirectory: @"/usr/local/bin" file: nil] == NSOKButton) {
		[[[NSUserDefaultsController sharedUserDefaultsController] values] setValue: [[openPanel filenames] objectAtIndex: 0] forKey: @"avrdudePath"];
		[self avrdudeChanged: nil];
	}
}

- (IBAction)avrdudeChanged: (id) sender
{
	[self loadAvrdudeConfigs];
}

- (IBAction)browseFlash:(id)sender
{
	NSOpenPanel *openPanel = [NSOpenPanel openPanel];
	[openPanel setCanChooseDirectories: NO];
	[openPanel setAllowsMultipleSelection: NO];
	if ([openPanel runModalForTypes: [NSArray arrayWithObject: @"hex"]] == NSOKButton) {
		[[[NSUserDefaultsController sharedUserDefaultsController] values] setValue: [[openPanel filenames] objectAtIndex: 0] forKey: @"lastSelectedFlash"];
	}
}

- (IBAction)browseEeprom:(id)sender
{
	NSOpenPanel *openPanel = [NSOpenPanel openPanel];
	[openPanel setCanChooseDirectories: NO];
	[openPanel setAllowsMultipleSelection: NO];
	if ([openPanel runModalForTypes: [NSArray arrayWithObject: @"hex"]] == NSOKButton) {
		[[[NSUserDefaultsController sharedUserDefaultsController] values] setValue: [[openPanel filenames] objectAtIndex: 0] forKey: @"lastSelectedEeprom"];
	}
}

- (void)log:(NSString *)s
{
	NSAttributedString *a = [[NSAttributedString alloc] initWithString: [NSString stringWithFormat: @"%@\n", s]];
	[a autorelease];
	[[logTextView textStorage] appendAttributedString: a];
	[logTextView scrollRangeToVisible: NSMakeRange([[logTextView textStorage] length], [[logTextView textStorage] length])];
}

- (BOOL) avrdudeAvailable
{
	//NSString *avrdudePort = [[NSUserDefaults standardUserDefaults] stringForKey: @"avrdudePort"];
	NSString *avrdudeConfig = [[NSUserDefaults standardUserDefaults] stringForKey: @"avrdudeConfig"];
	NSString *avrdudePath = [[NSUserDefaults standardUserDefaults] stringForKey: @"avrdudePath"];

	//return (avrdudePath && avrdudeConfig && avrdudePort && avrdudeVersion);
	return (avrdudePath && avrdudeConfig && avrdudeVersion);
}

- (void)loadAvrdudeConfigs
{
	NSString *avrdudePath = [[NSUserDefaults standardUserDefaults] stringForKey: @"avrdudePath"];

	[self willChangeValueForKey: @"avrdudeAvailable"];

	if (avrdudePath == nil) {
		[self didChangeValueForKey: @"avrdudeAvailable"];
		return;
	}
	
	avrdudeVersion = nil;
	[avrdudeConfigPopUpButton removeAllItems];
	
	NSMutableArray *avrdudeArguments = [[NSMutableArray alloc] init];
	[avrdudeArguments addObject: @"-v"];
	[avrdudeArguments addObject: @"-c"];
	[avrdudeArguments addObject: @"?"];
	
	[self log: @"Loading avrdude config..."];
	NSTask *task = [[NSTask alloc] init];
	[task setLaunchPath: avrdudePath];
	[task setArguments: avrdudeArguments];
	NSPipe *pipe = [NSPipe pipe];
	[task setStandardError: pipe];
	NSFileHandle *file = [pipe fileHandleForReading];
	NS_DURING
		[task launch];
		[task waitUntilExit];
		NSData *data = [file readDataToEndOfFile];
		NSString *configs = [[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding];
		NSArray *lines = [configs componentsSeparatedByString: @"\n"];
		for (int i = 0; i < [lines count]; i++) {
			NSString *line = [lines objectAtIndex: i];
			NSRange range;
			if (!avrdudeVersion) {
				range = [line rangeOfString: @"Version"];
				if (range.location != NSNotFound) {
					NSString *substr = [line substringFromIndex: range.location];
					NSArray *comps = [substr componentsSeparatedByString: @" "];
					comps = [[comps objectAtIndex: 1] componentsSeparatedByString: @","];
					avrdudeVersion = [comps objectAtIndex: 0];
				}
			}
			if (![line hasPrefix: @"   "] && [line hasPrefix: @"  "]) {
				NSArray *comps = [line componentsSeparatedByString: @" "];
				[avrdudeConfigPopUpButton addItemWithTitle: [comps objectAtIndex: 2]];
			}
		}
		[self log: @"SUCCESS"];
	NS_HANDLER
		NSAlert *alert = [[NSAlert alloc] init];
		[alert setMessageText: @"Unable to execute avrdude."];
		[alert setInformativeText: @"Check that the path to avrdude is correct and that you are able to execute it normally."];
		[alert addButtonWithTitle: @"OK"];
		[alert beginSheetModalForWindow: ([prefsWindow isVisible] ? prefsWindow : mainWindow)
			modalDelegate: nil 
			didEndSelector: nil
			contextInfo: nil];
	NS_ENDHANDLER
	
	if (avrdudeVersion) {
		[mainWindow setTitle: [NSString stringWithFormat: @"AVRFuses (avrdude v%@)", avrdudeVersion]];
		if ([[NSUserDefaults standardUserDefaults] stringForKey: @"avrdudeConfig"] != nil) {
			[avrdudeConfigPopUpButton selectItemWithTitle: [[NSUserDefaults standardUserDefaults] stringForKey: @"avrdudeConfig"]];
		}
	
		
	}
	else {
		[self log: @"FAILED"];
	}

	[self didChangeValueForKey: @"avrdudeAvailable"];
}

- (NSMutableArray *) defaultAvrdudeArguments
{
	NSString *avrdudePort = [[NSUserDefaults standardUserDefaults] stringForKey: @"avrdudePort"];
	NSString *avrdudeConfig = [[NSUserDefaults standardUserDefaults] stringForKey: @"avrdudeConfig"];
	NSString *avrdudeSerialBaud = [[NSUserDefaults standardUserDefaults] stringForKey: @"avrdudeSerialBaud"];
	//NSString *avrdudePath = [[NSUserDefaults standardUserDefaults] stringForKey: @"avrdudePath"];
	NSMutableArray *avrdudeArguments = [[NSMutableArray alloc] init];
	if (avrdudePort != nil && [avrdudePort length] > 0) {
		[avrdudeArguments addObject: @"-P"];
		[avrdudeArguments addObject: avrdudePort];
	}
	[avrdudeArguments addObject: @"-c"];
	[avrdudeArguments addObject: avrdudeConfig];
	if (avrdudeSerialBaud != nil && ![avrdudeSerialBaud isEqualToString: @"[Default]"]) {
		[avrdudeArguments addObject: @"-b"];
		[avrdudeArguments addObject: avrdudeSerialBaud];
	}
	[avrdudeArguments addObject: @"-p"];
	[avrdudeArguments addObject: selectedPart->name];
	[avrdudeArguments addObject: @"-qq"];
	[avrdudeArguments autorelease];
	//NSLog(@"%@", avrdudeArguments);
	return avrdudeArguments;
}

- (IBAction)programFuses:(id)sender
{
	NSString *avrdudePath = [[NSUserDefaults standardUserDefaults] stringForKey: @"avrdudePath"];
	NSMutableArray *avrdudeArguments = [self defaultAvrdudeArguments];
	
	for (int i = 0; i < [[fuses allKeys] count]; i++) {
		NSString *fuseName = [[fuses allKeys] objectAtIndex: i];
		NSString *avrdudeFuseName = nil;
		if ([fuseName isEqualToString: @"EXTENDED"]) {
			avrdudeFuseName = @"efuse";
		}
		else if ([fuseName isEqualToString: @"LOW"]) {
			avrdudeFuseName = @"lfuse";
		}
		else if ([fuseName isEqualToString: @"HIGH"]) {
			avrdudeFuseName = @"hfuse";
		}
		// TODO this pattern in the rest of these functions should change with addition of lockbits
		else {
			continue;
		}
		[avrdudeArguments addObject: @"-U"];
		[avrdudeArguments addObject: [NSString stringWithFormat: @"%@:w:0x%02x:m", avrdudeFuseName, [[fuses objectForKey: fuseName] unsignedCharValue]]];
	}
	[self log: @"Programming fuses..."];
	NSTask *task = [[NSTask alloc] init];
	[task setLaunchPath: avrdudePath];
	[task setArguments: avrdudeArguments];
	NSPipe *pipe = [NSPipe pipe];
	[task setStandardError: pipe];
	NSFileHandle *file = [pipe fileHandleForReading];
	[task launch];
	[task waitUntilExit];
	NSData *data = [file readDataToEndOfFile];
	NSString *stdErr = [[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding];
	NSArray *stdErrLines = [stdErr componentsSeparatedByString: @"\n"];
	for (int i = 0; i < [stdErrLines count]; i++) {
		NSString *line = [stdErrLines objectAtIndex: i];
		if ([line length] > 0) {
			[self log: line];
		}
	}
	if ([task terminationStatus] == 0) {
		[self log: @"SUCCESS"];
	}
	else {
		[self log: @"FAILED"];
	}
}

- (IBAction)readFuses:(id)sender
{
	NSString *avrdudePath = [[NSUserDefaults standardUserDefaults] stringForKey: @"avrdudePath"];
	NSMutableArray *avrdudeArguments = [self defaultAvrdudeArguments];
	
	for (int i = 0; i < [[fuses allKeys] count]; i++) {
		NSString *fuseName = [[fuses allKeys] objectAtIndex: i];
		NSString *avrdudeFuseName = nil;
		if ([fuseName isEqualToString: @"EXTENDED"]) {
			avrdudeFuseName = @"efuse";
		}
		else if ([fuseName isEqualToString: @"LOW"]) {
			avrdudeFuseName = @"lfuse";
		}
		else if ([fuseName isEqualToString: @"HIGH"]) {
			avrdudeFuseName = @"hfuse";
		}
		else {
			continue;
		}
		[avrdudeArguments addObject: @"-U"];
		[avrdudeArguments addObject: [NSString stringWithFormat: @"%@:r:/tmp/%@.tmp:h", avrdudeFuseName, fuseName]];
	}
	[self log: @"Reading fuses..."];
	NSTask *task = [[NSTask alloc] init];
	[task setLaunchPath: avrdudePath];
	[task setArguments: avrdudeArguments];
	NSPipe *pipe = [NSPipe pipe];
	[task setStandardError: pipe];
	NSFileHandle *file = [pipe fileHandleForReading];
	[task launch];
	[task waitUntilExit];
	NSData *data = [file readDataToEndOfFile];
	NSString *stdErr = [[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding];
	NSArray *stdErrLines = [stdErr componentsSeparatedByString: @"\n"];
	for (int i = 0; i < [stdErrLines count]; i++) {
		NSString *line = [stdErrLines objectAtIndex: i];
		if ([line length] > 0) {
			[self log: line];
		}
	}
	if ([task terminationStatus] == 0) {
		[self log: @"SUCCESS"];
		for (int i = 0; i < [[fuses allKeys] count]; i++) {
			NSString *fuseName = [[fuses allKeys] objectAtIndex: i];
			//NSLog(@"%@", fuseName);
			char buffer[1000];
			FILE *file = fopen([[NSString stringWithFormat: @"/tmp/%@.tmp", fuseName] cString], "r");
			fgets(buffer, 1000, file);
			NSString *line = [[NSString alloc] initWithCString: buffer];
			NSScanner *scanner = [NSScanner scannerWithString: line];
			unsigned int fuseValue;
			[scanner scanHexInt: &fuseValue];
			fclose(file);
			[fuses setObject: [NSNumber numberWithUnsignedChar: (fuseValue & 0xff)] forKey: fuseName];
		}
	}
	else {
		[self log: @"FAILED"];
	}
	[fusesTableView reloadData];
}

- (IBAction)verifyFuses:(id)sender
{
	NSString *avrdudePath = [[NSUserDefaults standardUserDefaults] stringForKey: @"avrdudePath"];
	NSMutableArray *avrdudeArguments = [self defaultAvrdudeArguments];

	for (int i = 0; i < [[fuses allKeys] count]; i++) {
		NSString *fuseName = [[fuses allKeys] objectAtIndex: i];
		NSString *avrdudeFuseName = nil;
		if ([fuseName isEqualToString: @"EXTENDED"]) {
			avrdudeFuseName = @"efuse";
		}
		else if ([fuseName isEqualToString: @"LOW"]) {
			avrdudeFuseName = @"lfuse";
		}
		else if ([fuseName isEqualToString: @"HIGH"]) {
			avrdudeFuseName = @"hfuse";
		}
		else {
			continue;
		}
		[avrdudeArguments addObject: @"-U"];
		[avrdudeArguments addObject: [NSString stringWithFormat: @"%@:v:0x%02x:m", avrdudeFuseName, [[fuses objectForKey: fuseName] unsignedCharValue]]];
	}
	[self log: @"Verifying fuses..."];
	NSTask *task = [[NSTask alloc] init];
	[task setLaunchPath: avrdudePath];
	[task setArguments: avrdudeArguments];
	NSPipe *pipe = [NSPipe pipe];
	[task setStandardError: pipe];
	NSFileHandle *file = [pipe fileHandleForReading];
	[task launch];
	[task waitUntilExit];
	NSData *data = [file readDataToEndOfFile];
	NSString *stdErr = [[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding];
	NSArray *stdErrLines = [stdErr componentsSeparatedByString: @"\n"];
	for (int i = 0; i < [stdErrLines count]; i++) {
		NSString *line = [stdErrLines objectAtIndex: i];
		if ([line length] > 0) {
			[self log: line];
		}
	}
	if ([task terminationStatus] == 0) {
		[self log: @"SUCCESS"];
	}
	else {
		[self log: @"FAILED"];
	}
	[fusesTableView reloadData];
}

// TODO
/*
- (IBAction)programLockbits:(id)sender
{
	NSString *avrdudePath = [[NSUserDefaults standardUserDefaults] stringForKey: @"avrdudePath"];
	NSMutableArray *avrdudeArguments = [self defaultAvrdudeArguments];
	
	for (int i = 0; i < [[fuses allKeys] count]; i++) {
		NSString *fuseName = [[fuses allKeys] objectAtIndex: i];
		NSString *avrdudeFuseName = nil;
		if ([fuseName isEqualToString: @"EXTENDED"]) {
			avrdudeFuseName = @"efuse";
		}
		else if ([fuseName isEqualToString: @"LOW"]) {
			avrdudeFuseName = @"lfuse";
		}
		else if ([fuseName isEqualToString: @"HIGH"]) {
			avrdudeFuseName = @"hfuse";
		}
		[avrdudeArguments addObject: @"-U"];
		[avrdudeArguments addObject: [NSString stringWithFormat: @"%@:w:0x%02x:m", avrdudeFuseName, [[fuses objectForKey: fuseName] unsignedCharValue]]];
	}
	[self log: @"Programming fuses..."];
	NSTask *task = [[NSTask alloc] init];
	[task setLaunchPath: avrdudePath];
	[task setArguments: avrdudeArguments];
	NSPipe *pipe = [NSPipe pipe];
	[task setStandardError: pipe];
	NSFileHandle *file = [pipe fileHandleForReading];
	[task launch];
	[task waitUntilExit];
	NSData *data = [file readDataToEndOfFile];
	NSString *stdErr = [[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding];
	NSArray *stdErrLines = [stdErr componentsSeparatedByString: @"\n"];
	for (int i = 0; i < [stdErrLines count]; i++) {
		NSString *line = [stdErrLines objectAtIndex: i];
		if ([line length] > 0) {
			[self log: line];
		}
	}
	if ([task terminationStatus] == 0) {
		[self log: @"SUCCESS"];
	}
	else {
		[self log: @"FAILED"];
	}
}

- (IBAction)readLockbits:(id)sender
{
	NSString *avrdudePath = [[NSUserDefaults standardUserDefaults] stringForKey: @"avrdudePath"];
	NSMutableArray *avrdudeArguments = [self defaultAvrdudeArguments];
	
	NSString *fuseName = @"LOCKBIT";
	NSString *avrdudeFuseName = @"lock";
	[avrdudeArguments addObject: @"-U"];
	[avrdudeArguments addObject: [NSString stringWithFormat: @"%@:r:/tmp/%@.tmp:h", avrdudeFuseName, fuseName]];

	[self log: @"Reading lock bits..."];
	NSTask *task = [[NSTask alloc] init];
	[task setLaunchPath: avrdudePath];
	[task setArguments: avrdudeArguments];
	NSPipe *pipe = [NSPipe pipe];
	[task setStandardError: pipe];
	NSFileHandle *file = [pipe fileHandleForReading];
	[task launch];
	[task waitUntilExit];
	NSData *data = [file readDataToEndOfFile];
	NSString *stdErr = [[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding];
	NSArray *stdErrLines = [stdErr componentsSeparatedByString: @"\n"];
	for (int i = 0; i < [stdErrLines count]; i++) {
		NSString *line = [stdErrLines objectAtIndex: i];
		if ([line length] > 0) {
			[self log: line];
		}
	}
	if ([task terminationStatus] == 0) {
		[self log: @"SUCCESS"];
		char buffer[1000];
		FILE *file = fopen([[NSString stringWithFormat: @"/tmp/%@.tmp", fuseName] cString], "r");
		fgets(buffer, 1000, file);
		NSString *line = [[NSString alloc] initWithCString: buffer];
		NSScanner *scanner = [NSScanner scannerWithString: line];
		unsigned int fuseValue;
		[scanner scanHexInt: &fuseValue];
		fclose(file);
		[fuses setObject: [NSNumber numberWithUnsignedChar: (fuseValue & 0xff)] forKey: fuseName];
	}
	else {
		[self log: @"FAILED"];
	}
	[lockbitsTableView reloadData];
}

- (IBAction)verifyLockbits:(id)sender
{
	NSString *avrdudePath = [[NSUserDefaults standardUserDefaults] stringForKey: @"avrdudePath"];
	NSMutableArray *avrdudeArguments = [self defaultAvrdudeArguments];

	for (int i = 0; i < [[fuses allKeys] count]; i++) {
		NSString *fuseName = [[fuses allKeys] objectAtIndex: i];
		NSString *avrdudeFuseName = nil;
		if ([fuseName isEqualToString: @"EXTENDED"]) {
			avrdudeFuseName = @"efuse";
		}
		else if ([fuseName isEqualToString: @"LOW"]) {
			avrdudeFuseName = @"lfuse";
		}
		else if ([fuseName isEqualToString: @"HIGH"]) {
			avrdudeFuseName = @"hfuse";
		}
		[avrdudeArguments addObject: @"-U"];
		[avrdudeArguments addObject: [NSString stringWithFormat: @"%@:v:0x%02x:m", avrdudeFuseName, [[fuses objectForKey: fuseName] unsignedCharValue]]];
	}
	[self log: @"Verifying fuses..."];
	NSTask *task = [[NSTask alloc] init];
	[task setLaunchPath: avrdudePath];
	[task setArguments: avrdudeArguments];
	NSPipe *pipe = [NSPipe pipe];
	[task setStandardError: pipe];
	NSFileHandle *file = [pipe fileHandleForReading];
	[task launch];
	[task waitUntilExit];
	NSData *data = [file readDataToEndOfFile];
	NSString *stdErr = [[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding];
	NSArray *stdErrLines = [stdErr componentsSeparatedByString: @"\n"];
	for (int i = 0; i < [stdErrLines count]; i++) {
		NSString *line = [stdErrLines objectAtIndex: i];
		if ([line length] > 0) {
			[self log: line];
		}
	}
	if ([task terminationStatus] == 0) {
		[self log: @"SUCCESS"];
	}
	else {
		[self log: @"FAILED"];
	}
	[fusesTableView reloadData];
}
*/

- (IBAction)verifyFlash:(id)sender
{
	NSString *avrdudePath = [[NSUserDefaults standardUserDefaults] stringForKey: @"avrdudePath"];
	NSMutableArray *avrdudeArguments = [self defaultAvrdudeArguments];
	
	[avrdudeArguments addObject: @"-U"];
	[avrdudeArguments addObject: [NSString stringWithFormat: @"flash:v:%@", 
		[[NSUserDefaults standardUserDefaults] stringForKey: @"lastSelectedFlash"]]];
	[self log: @"Verifying flash..."];
	NSTask *task = [[NSTask alloc] init];
	[task setLaunchPath: avrdudePath];
	[task setArguments: avrdudeArguments];
	NSPipe *pipe = [NSPipe pipe];
	[task setStandardError: pipe];
	NSFileHandle *file = [pipe fileHandleForReading];
	[task launch];
	[task waitUntilExit];
	NSData *data = [file readDataToEndOfFile];
	NSString *stdErr = [[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding];
	NSArray *stdErrLines = [stdErr componentsSeparatedByString: @"\n"];
	for (int i = 0; i < [stdErrLines count]; i++) {
		NSString *line = [stdErrLines objectAtIndex: i];
		if ([line length] > 0) {
			[self log: line];
		}
	}
	if ([task terminationStatus] == 0) {
		[self log: @"SUCCESS"];
	}
	else {
		[self log: @"FAILED"];
	}
}

- (IBAction)programFlash:(id)sender
{
	NSString *avrdudePath = [[NSUserDefaults standardUserDefaults] stringForKey: @"avrdudePath"];
	NSMutableArray *avrdudeArguments = [self defaultAvrdudeArguments];
	
	[avrdudeArguments addObject: @"-U"];
	[avrdudeArguments addObject: [NSString stringWithFormat: @"flash:w:%@", 
		[[NSUserDefaults standardUserDefaults] stringForKey: @"lastSelectedFlash"]]];
	[self log: @"Programming flash..."];
	NSTask *task = [[NSTask alloc] init];
	[task setLaunchPath: avrdudePath];
	[task setArguments: avrdudeArguments];
	NSPipe *pipe = [NSPipe pipe];
	[task setStandardError: pipe];
	NSFileHandle *file = [pipe fileHandleForReading];
	[task launch];
	[task waitUntilExit];
	NSData *data = [file readDataToEndOfFile];
	NSString *stdErr = [[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding];
	NSArray *stdErrLines = [stdErr componentsSeparatedByString: @"\n"];
	for (int i = 0; i < [stdErrLines count]; i++) {
		NSString *line = [stdErrLines objectAtIndex: i];
		if ([line length] > 0) {
			[self log: line];
		}
	}
	if ([task terminationStatus] == 0) {
		[self log: @"SUCCESS"];
	}
	else {
		[self log: @"FAILED"];
	}
}

- (void) readFlashAlertDidEnd: (NSAlert *) alert returnCode: (int) returnCode contextInfo: (void *) contextInfo
{
	[[alert window] orderOut: self];
	if (returnCode == NSAlertFirstButtonReturn) {
		[self readFlash: nil];
	}
}

- (IBAction)readFlash:(id)sender
{
	NSString *filename = [[NSUserDefaults standardUserDefaults] stringForKey: @"lastSelectedFlash"];
	if (sender != nil && [[NSFileManager defaultManager] fileExistsAtPath: filename]) {
		NSAlert *alert = [[NSAlert alloc] init];
		[alert setMessageText: 
			[NSString stringWithFormat: @"\"%@\" already exists. Do you want to replace it?", 
				[[NSFileManager defaultManager] displayNameAtPath: filename]]];
		[alert setInformativeText: @"A file or folder with the same name already exists. Replacing it will overwrite it's current contents."];
		[alert addButtonWithTitle: @"Replace"];
		[alert addButtonWithTitle: @"Cancel"];
		[alert beginSheetModalForWindow: mainWindow 
			modalDelegate: self 
			didEndSelector: @selector(readFlashAlertDidEnd:returnCode:contextInfo:) 
			contextInfo: nil];
		return;
	}

	NSString *avrdudePath = [[NSUserDefaults standardUserDefaults] stringForKey: @"avrdudePath"];
	NSMutableArray *avrdudeArguments = [self defaultAvrdudeArguments];
	
	[avrdudeArguments addObject: @"-U"];
	[avrdudeArguments addObject: [NSString stringWithFormat: @"flash:r:%@:i", filename]];
	[self log: @"Reading flash..."];
	NSTask *task = [[NSTask alloc] init];
	[task setLaunchPath: avrdudePath];
	[task setArguments: avrdudeArguments];
	NSPipe *pipe = [NSPipe pipe];
	[task setStandardError: pipe];
	NSFileHandle *file = [pipe fileHandleForReading];
	[task launch];
	[task waitUntilExit];
	NSData *data = [file readDataToEndOfFile];
	NSString *stdErr = [[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding];
	NSArray *stdErrLines = [stdErr componentsSeparatedByString: @"\n"];
	for (int i = 0; i < [stdErrLines count]; i++) {
		NSString *line = [stdErrLines objectAtIndex: i];
		if ([line length] > 0) {
			[self log: line];
		}
	}
	if ([task terminationStatus] == 0) {
		[self log: @"SUCCESS"];
	}
	else {
		[self log: @"FAILED"];
	}
}

- (IBAction)verifyEeprom:(id)sender
{
	NSString *avrdudePath = [[NSUserDefaults standardUserDefaults] stringForKey: @"avrdudePath"];
	NSMutableArray *avrdudeArguments = [self defaultAvrdudeArguments];
	
	[avrdudeArguments addObject: @"-U"];
	[avrdudeArguments addObject: [NSString stringWithFormat: @"eeprom:v:%@", 
		[[NSUserDefaults standardUserDefaults] stringForKey: @"lastSelectedEeprom"]]];
	[self log: @"Verifying EEPROM..."];
	NSTask *task = [[NSTask alloc] init];
	[task setLaunchPath: avrdudePath];
	[task setArguments: avrdudeArguments];
	NSPipe *pipe = [NSPipe pipe];
	[task setStandardError: pipe];
	NSFileHandle *file = [pipe fileHandleForReading];
	[task launch];
	[task waitUntilExit];
	NSData *data = [file readDataToEndOfFile];
	NSString *stdErr = [[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding];
	NSArray *stdErrLines = [stdErr componentsSeparatedByString: @"\n"];
	for (int i = 0; i < [stdErrLines count]; i++) {
		NSString *line = [stdErrLines objectAtIndex: i];
		if ([line length] > 0) {
			[self log: line];
		}
	}
	if ([task terminationStatus] == 0) {
		[self log: @"SUCCESS"];
	}
	else {
		[self log: @"FAILED"];
	}
}

- (IBAction)programEeprom:(id)sender
{
	NSString *avrdudePath = [[NSUserDefaults standardUserDefaults] stringForKey: @"avrdudePath"];
	NSMutableArray *avrdudeArguments = [self defaultAvrdudeArguments];
	
	[avrdudeArguments addObject: @"-U"];
	[avrdudeArguments addObject: [NSString stringWithFormat: @"eeprom:w:%@", 
		[[NSUserDefaults standardUserDefaults] stringForKey: @"lastSelectedEeprom"]]];
	[self log: @"Programming EEPROM..."];
	NSTask *task = [[NSTask alloc] init];
	[task setLaunchPath: avrdudePath];
	[task setArguments: avrdudeArguments];
	NSPipe *pipe = [NSPipe pipe];
	[task setStandardError: pipe];
	NSFileHandle *file = [pipe fileHandleForReading];
	[task launch];
	[task waitUntilExit];
	NSData *data = [file readDataToEndOfFile];
	NSString *stdErr = [[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding];
	NSArray *stdErrLines = [stdErr componentsSeparatedByString: @"\n"];
	for (int i = 0; i < [stdErrLines count]; i++) {
		NSString *line = [stdErrLines objectAtIndex: i];
		if ([line length] > 0) {
			[self log: line];
		}
	}
	if ([task terminationStatus] == 0) {
		[self log: @"SUCCESS"];
	}
	else {
		[self log: @"FAILED"];
	}
}

- (void) readEepromAlertDidEnd: (NSAlert *) alert returnCode: (int) returnCode contextInfo: (void *) contextInfo
{
	[[alert window] orderOut: self];
	if (returnCode == NSAlertFirstButtonReturn) {
		[self readEeprom: nil];
	}
}

- (IBAction)readEeprom:(id)sender
{
	NSString *filename = [[NSUserDefaults standardUserDefaults] stringForKey: @"lastSelectedEeprom"];
	if (sender != nil && [[NSFileManager defaultManager] fileExistsAtPath: filename]) {
		NSAlert *alert = [[NSAlert alloc] init];
		[alert setMessageText: 
			[NSString stringWithFormat: @"\"%@\" already exists. Do you want to replace it?", 
				[[NSFileManager defaultManager] displayNameAtPath: filename]]];
		[alert setInformativeText: @"A file or folder with the same name already exists. Replacing it will overwrite it's current contents."];
		[alert addButtonWithTitle: @"Replace"];
		[alert addButtonWithTitle: @"Cancel"];
		[alert beginSheetModalForWindow: mainWindow 
			modalDelegate: self 
			didEndSelector: @selector(readEepromAlertDidEnd:returnCode:contextInfo:) 
			contextInfo: nil];
		return;
	}
	
	NSString *avrdudePath = [[NSUserDefaults standardUserDefaults] stringForKey: @"avrdudePath"];
	NSMutableArray *avrdudeArguments = [self defaultAvrdudeArguments];
	
	[avrdudeArguments addObject: @"-U"];
	[avrdudeArguments addObject: [NSString stringWithFormat: @"eeprom:r:%@:i", filename]];
	[self log: @"Reading EEPROM..."];
	NSTask *task = [[NSTask alloc] init];
	[task setLaunchPath: avrdudePath];
	[task setArguments: avrdudeArguments];
	NSPipe *pipe = [NSPipe pipe];
	[task setStandardError: pipe];
	NSFileHandle *file = [pipe fileHandleForReading];
	[task launch];
	[task waitUntilExit];
	NSData *data = [file readDataToEndOfFile];
	NSString *stdErr = [[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding];
	NSArray *stdErrLines = [stdErr componentsSeparatedByString: @"\n"];
	for (int i = 0; i < [stdErrLines count]; i++) {
		NSString *line = [stdErrLines objectAtIndex: i];
		if ([line length] > 0) {
			[self log: line];
		}
	}
	if ([task terminationStatus] == 0) {
		[self log: @"SUCCESS"];
	}
	else {
		[self log: @"FAILED"];
	}
}

- (IBAction)eraseDevice:(id)sender
{
	NSString *avrdudePath = [[NSUserDefaults standardUserDefaults] stringForKey: @"avrdudePath"];
	NSMutableArray *avrdudeArguments = [self defaultAvrdudeArguments];

	[avrdudeArguments addObject: @"-e"];
	[self log: @"Erasing chip..."];
	NSTask *task = [[NSTask alloc] init];
	[task setLaunchPath: avrdudePath];
	[task setArguments: avrdudeArguments];
	NSPipe *pipe = [NSPipe pipe];
	[task setStandardError: pipe];
	NSFileHandle *file = [pipe fileHandleForReading];
	[task launch];
	[task waitUntilExit];
	NSData *data = [file readDataToEndOfFile];
	NSString *stdErr = [[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding];
	NSArray *stdErrLines = [stdErr componentsSeparatedByString: @"\n"];
	for (int i = 0; i < [stdErrLines count]; i++) {
		NSString *line = [stdErrLines objectAtIndex: i];
		if ([line length] > 0) {
			[self log: line];
		}
	}
	if ([task terminationStatus] == 0) {
		[self log: @"SUCCESS"];
	}
	else {
		[self log: @"FAILED"];
	}
}

- (void)tableViewDoubleClick: (NSTableView *) tableView
{
	if (![self avrdudeAvailable]) {
		return;
	}

	NSMutableArray *settings = nil;
	if (tableView == fusesTableView) {
		settings = fuseSettings;
	}
	else if (tableView == lockbitsTableView) {
		settings = lockbitSettings;
	}

	FuseSetting *fuseSetting = [settings objectAtIndex: [tableView selectedRow]];
	
	unsigned char fuseValue = [[fuses objectForKey: fuseSetting->fuse] intValue];

	BOOL singleElementGroup = YES;
	for (int i = 0; i < [settings count]; i++) {
		FuseSetting *fuseSetting1 = [settings objectAtIndex: i];
		if (fuseSetting1 != fuseSetting && 
			[fuseSetting1->fuse isEqualToString: fuseSetting->fuse] &&
			fuseSetting1->mask == fuseSetting->mask) {
			singleElementGroup = NO;
			break;
		}
	}
	
	if (singleElementGroup) {
		fuseValue ^= fuseSetting->mask;
	}
	else if ((fuseValue & fuseSetting->mask) != fuseSetting->value) {
		fuseValue |= fuseSetting->mask;
		fuseValue &= (~(fuseSetting->mask) | fuseSetting->value);
	}
	
	[fuses setObject: [NSNumber numberWithUnsignedChar: fuseValue] forKey: fuseSetting->fuse];
	
	[tableView reloadData];
}

- (int)numberOfRowsInTableView:(NSTableView *)tableView
{
	if (tableView == fusesTableView) {
		return [fuseSettings count];
	}
	else if (tableView == lockbitsTableView) {
		return [lockbitSettings count];
	}
	return 0;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *) column row:(int)row
{
	NSMutableArray *settings = nil;
	if (tableView == fusesTableView) {
		settings = fuseSettings;
	}
	else if (tableView == lockbitsTableView) {
		settings = lockbitSettings;
	}
	if ([[column identifier] isEqual:@"checkbox"]) {
		FuseSetting *fuseSetting = [settings objectAtIndex: row];
		unsigned char fuseValue = [[fuses objectForKey: fuseSetting->fuse] intValue];
		return ((fuseValue & fuseSetting->mask) == fuseSetting->value) ? @"1" : @"0";
	}
	else if ([[column identifier] isEqual:@"fuse"]) {
		FuseSetting *fuseSetting = [settings objectAtIndex: row];
		return fuseSetting->text;
	}
	
	return nil;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *) theApplication
{
	return YES;
}

- (float)splitView:(NSSplitView *)sender constrainMinCoordinate:(float)proposedMin ofSubviewAt:(int)offset
{
	if (offset == 0) {
		return 388.0;
	}
	return 0.0;
}

- (NSString *)getNextSerialPort:(io_iterator_t)serialPortIterator
{
	NSString *serialPort = nil;
	io_object_t serialService = IOIteratorNext(serialPortIterator);
	if (serialService != 0) {
		CFStringRef modemName = (CFStringRef)IORegistryEntryCreateCFProperty(serialService, CFSTR(kIOTTYDeviceKey), kCFAllocatorDefault, 0);
		CFStringRef bsdPath = (CFStringRef)IORegistryEntryCreateCFProperty(serialService, CFSTR(kIOCalloutDeviceKey), kCFAllocatorDefault, 0);
		CFStringRef serviceType = (CFStringRef)IORegistryEntryCreateCFProperty(serialService, CFSTR(kIOSerialBSDTypeKey), kCFAllocatorDefault, 0);
		if (modemName && bsdPath) {
			serialPort = [NSString stringWithString: (NSString *) bsdPath];
		}
		CFRelease(modemName);
		CFRelease(bsdPath);
		CFRelease(serviceType);
		
		// We have sucked this service dry of information so release it now.
		(void)IOObjectRelease(serialService);
	}
	return serialPort;
}

- (void)addAllSerialPortsToArray:(NSMutableArray *)array
{
	NSString *serialPort;
	kern_return_t kernResult; 
	CFMutableDictionaryRef classesToMatch;
	io_iterator_t serialPortIterator;
	
	// Serial devices are instances of class IOSerialBSDClient
	classesToMatch = IOServiceMatching(kIOSerialBSDServiceValue);
	if (classesToMatch != NULL) {
		CFDictionarySetValue(classesToMatch, CFSTR(kIOSerialBSDTypeKey), CFSTR(kIOSerialBSDAllTypes));

		// This function decrements the refcount of the dictionary passed it
		kernResult = IOServiceGetMatchingServices(kIOMasterPortDefault, classesToMatch, &serialPortIterator);    
		if (kernResult == KERN_SUCCESS) {			
			while ((serialPort = [self getNextSerialPort:serialPortIterator]) != nil) {
				[array addObject: serialPort];
			}
			(void)IOObjectRelease(serialPortIterator);
		} else {
			NSLog(@"IOServiceGetMatchingServices returned %d", kernResult);
		}
	} else {
		NSLog(@"IOServiceMatching returned a NULL dictionary.");
	}
}
@end
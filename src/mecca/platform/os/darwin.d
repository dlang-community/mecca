module mecca.platform.os.darwin;

package(mecca):

// This does not exist on Darwin platforms. We'll just use a value that won't
// have any affect when used together with mmap.
enum MAP_POPULATE = 0;

import io
from pathlib import Path
import tarfile
import tempfile
import unittest

source = (Path(__file__).resolve().parents[1] / 'scripts/install.sh').read_text().split("<<'PYTHON'\n", 1)[1].rsplit('\nPYTHON', 1)[0]
namespace = {'__name__': 'installer_test'}
exec(compile(source, 'install.sh embedded python', 'exec'), namespace)


class InstallerTests(unittest.TestCase):
    def archive(self, name, kind=None):
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode='w:gz') as archive:
            info = tarfile.TarInfo(name)
            if kind:
                info.type = kind;info.linkname = '/etc/passwd'
                archive.addfile(info)
            else:
                info.size = 2
                archive.addfile(info, io.BytesIO(b'ok'))
        return data.getvalue()

    def test_extract_regular_file(self):
        with tempfile.TemporaryDirectory() as directory:
            namespace['safe_extract'](self.archive('repo/scripts/test.py'), Path(directory))
            self.assertEqual((Path(directory) / 'scripts/test.py').read_text(), 'ok')

    def test_reject_traversal_and_links(self):
        for name, kind in [('repo/../escape', None), ('/absolute', None),
                           ('repo/symlink', tarfile.SYMTYPE), ('repo/hardlink', tarfile.LNKTYPE)]:
            with tempfile.TemporaryDirectory() as directory, self.assertRaises(ValueError):
                namespace['safe_extract'](self.archive(name, kind), Path(directory))

    def test_mutable_ref_rejected_before_authentication(self):
        with self.assertRaises(ValueError):
            namespace['install']('main', Path('/not-used'))


if __name__ == '__main__':
    unittest.main()

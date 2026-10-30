package dev.droidbridge.companion;
import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import java.util.*;
import java.io.*;
/** Test APK only, unexported; two nonce-scoped reliable pipes never send bytes. */
public final class StalledTransferProvider extends ContentProvider {
    private final Map<String,ParcelFileDescriptor> writers=new LinkedHashMap<>();
    @Override public boolean onCreate(){return true;}
    private List<String> path(Uri uri){List<String> p=uri.getPathSegments();if(p.size()<2||p.size()>3||!UUID.fromString(p.get(1)).toString().equals(p.get(1)))throw new IllegalArgumentException();return p;}
    @Override public String getType(Uri uri){return "application/octet-stream";}
    @Override public synchronized Cursor query(Uri uri,String[] projection,String selection,String[] args,String order){
        List<String> p=path(uri);
        if(p.get(0).equals("status")){int count=0;for(String key:writers.keySet())if(key.contains(p.get(1)))count++;MatrixCursor c=new MatrixCursor(new String[]{"open_pipes"});c.addRow(new Object[]{count});return c;}
        MatrixCursor c=new MatrixCursor(new String[]{OpenableColumns.DISPLAY_NAME});c.addRow(new Object[]{p.get(0)+".bin"});return c;
    }
    @Override public synchronized ParcelFileDescriptor openFile(Uri uri,String mode)throws FileNotFoundException{
        if(!"r".equals(mode))throw new FileNotFoundException();List<String> p=path(uri);
        try{
            ParcelFileDescriptor[] pipe=ParcelFileDescriptor.createReliablePipe();String kind=p.get(0);
            if(kind.equals("stall")){
                if(p.size()!=3||!Arrays.asList("a","b").contains(p.get(2))||writers.size()>=2){for(ParcelFileDescriptor fd:pipe)fd.close();throw new FileNotFoundException("Fixture full");}
                writers.put(uri.toString(),pipe[1]);
            }else if(kind.equals("small")){
                try(OutputStream out=new ParcelFileDescriptor.AutoCloseOutputStream(pipe[1])){out.write("actual provider bytes".getBytes("UTF-8"));}
            }else if(kind.equals("cleanup")){
                for(String key:new ArrayList<>(writers.keySet()))if(key.contains(p.get(1)))writers.remove(key).close();pipe[1].close();
            }else{for(ParcelFileDescriptor fd:pipe)fd.close();throw new FileNotFoundException("Unknown fixture");}
            return pipe[0];
        }catch(IOException failure){throw new FileNotFoundException(failure.toString());}
    }
    @Override public Uri insert(Uri uri,ContentValues values){throw new UnsupportedOperationException();}
    @Override public int update(Uri uri,ContentValues values,String selection,String[] args){throw new UnsupportedOperationException();}
    @Override public int delete(Uri uri,String selection,String[] args){throw new UnsupportedOperationException();}
}
